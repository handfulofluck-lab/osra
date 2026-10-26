import { randomUUID } from "node:crypto";
import type { FastifyBaseLogger, FastifyInstance } from "fastify";
import { Redis } from "ioredis";
import { getRedis } from "../redis.js";
import { prisma } from "../db.js";
import { isBearerSession, isParentSessionLive } from "../lib/sessions.js";

// The gateway needs a DEDICATED subscriber connection (psubscribe switches a connection
// into subscriber mode); publishing reuses the shared lazy publisher via getRedis().
const subscriber = new Redis(process.env.REDIS_URL ?? "redis://localhost:6379");
const socketsByFamily = new Map<string, Set<any>>();

/**
 * The permission each family event type needs from a **guardian** (ADR-0014 amendment, decision 3).
 * Owners and co-parents are unaffected, so only these two are listed; an event type absent here is
 * never withheld.
 */
const EVENT_PERMISSION: Record<string, "alerts" | "location"> = { alert: "alerts", location: "location" };

/** What one socket may receive. `guardian: false` means no frame is ever withheld from it. */
type SocketGate = { guardian: boolean; allowed: Set<string> };

const OPEN_GATE: SocketGate = { guardian: false, allowed: new Set() };

const socketGates = new WeakMap<object, SocketGate>();

/**
 * Resolve a subscriber's gate once, at connect. A device or an unknown parent gets `OPEN_GATE`: the
 * ticket route already refuses anything that is not a live parent session, and the amendment gates
 * guardians, not absence.
 */
async function gateFor(parentId: string | null): Promise<SocketGate> {
  if (!parentId) return OPEN_GATE;
  // A failure here is not a reason to refuse a socket: the ticket already proved a live parent
  // session, and closing the stream on a transient database error would be a new outage path.
  try {
    const row = await prisma.parent.findUnique({ where: { id: parentId }, select: { role: true, permissions: true } });
    if (!row || row.role !== "guardian") return OPEN_GATE;
    return { guardian: true, allowed: new Set(row.permissions) };
  } catch {
    return OPEN_GATE;
  }
}

/**
 * Issue #350: a delivery miss on this path used to leave no evidence at all — the publish was a bare
 * `redis.publish` with its return value dropped, and the subscriber installed `on("error", () => {})`,
 * so a reconnect window (the likeliest way a frame is dropped) was silent by construction. A reviewer
 * could not tell "never published" from "published with nobody listening" from "delivered, the client
 * missed it". The two lines below and the error handler close that gap.
 *
 * The logger is Fastify's own, handed in by `registerRealtime` — the same pino instance, at the same
 * `LOG_LEVEL`, that writes the request lines. No second logging stack. Until a process calls
 * `registerRealtime` there is no logger and nothing is written; that window is boot only, because
 * `src/server.ts` calls it before `listen()`.
 *
 * Every field here is `familyId`, the event `type` and a count. Never the payload, a ticket, an id or
 * an address — those lines reach the same sink as the access log.
 */
let gatewayLog: FastifyBaseLogger | null = null;

let subscriberErrors = 0;

/**
 * Issue #350: this handler used to be `() => {}`. A reconnect is logged at `warn` with the error and a
 * running count, and the subscriber is left alone — ioredis retries by itself, and throwing from here
 * would only kill the process that is holding every family's socket.
 */
subscriber.on("error", (err) => {
  subscriberErrors += 1;
  gatewayLog?.warn({ err, subscriberErrors }, "realtime subscriber error (ioredis reconnects; sockets unchanged)");
});

/** In-memory count of subscriber `error` events since boot (#350); a restart resets it to 0. */
export function subscriberErrorCount(): number {
  return subscriberErrors;
}

/** The event `type` every producer sets (`{ type: "alert", payload, ts }` — src/lib/alerts.ts:80). */
export function eventType(event: unknown): string {
  const type = (event as { type?: unknown } | null | undefined)?.type;
  return typeof type === "string" && type.length > 0 ? type : "unknown";
}

/**
 * Name the frame's type without changing it: the raw string is what the sockets receive, so a frame that
 * is not JSON still goes out as it always did and is logged as `unknown` rather than dropped here.
 */
function frameType(message: string): string {
  try {
    return eventType(JSON.parse(message));
  } catch {
    return "unknown";
  }
}

/** Serialise and send one frame if the socket is still open; a closed socket is not an error. */
function sendFrame(socket: { readyState: number; send: (data: string) => void }, frame: unknown) {
  if (socket.readyState === 1) socket.send(JSON.stringify(frame));
}

export function registerRealtime(app: FastifyInstance) {
  // #350: the module has no request, so the Fastify logger is the one thing that ties these lines to the
  // request lines a reviewer reads next to them — same pino instance, same level, same sink.
  gatewayLog = app.log;
  /**
   * Handoff item 6: issue a short-lived, single-use WS ticket so the JWT never travels
   * in the URL (proxy/access-log hygiene). The ticket maps to the caller's familyId.
   */
  app.post("/v1/ws-ticket", async (req, reply) => {
    try {
      await req.jwtVerify();
    } catch {
      return reply.code(401).send({ error: "unauthorized" });
    }
    const user = req.user as { role?: string; familyId?: string; deviceId?: string; purpose?: string };
    // Plan 2.7 Q4 (Claude, #329): a purpose-scoped token (password reset, MFA recovery/reset) is not a
    // bearer credential here either (#146) — 401 like every other route, not the 403 the role check gives.
    if (!isBearerSession(user)) {
      return reply.code(401).send({ error: "unauthorized" });
    }
    // #351: revocation is sessionGuard's answer (server.ts), which runs before every route. The copy
    // here was a second Redis GET for an answer the hook had already given.
    if (user.role !== "parent") {
      return reply.code(403).send({ error: "parent_role_required" });
    }
    // Plan 2.7 F5 (Claude, #329): the ticket opens the family's live socket, so a revoked parent session
    // is refused here too, not only by the global hook (probe Q2 with that branch removed: 200).
    if (!(await isParentSessionLive(user as { sub?: string; jti?: string; iat?: number; sv?: number }))) {
      return reply.code(401).send({ error: "session_revoked" });
    }
    const ticket = randomUUID();
    const familyId = user.familyId ?? "";
    // ADR-0014 amendment, decision 3 (second half, #402): the ticket carries WHO is subscribing, so the
    // fan-out can drop a frame this reader is not allowed to see. The app sends the same ticket either
    // way; only the stored value changed.
    await getRedis().set(`ws:ticket:${ticket}`, JSON.stringify({ familyId, parentId: (user as { sub?: string }).sub ?? null }), "EX", 60);
    return { ticket, expiresIn: 60 };
  });

  // NOTE: @fastify/websocket v10 passes the ws.WebSocket directly (older versions
  // passed a connection object with a `.socket` property).
  app.get(
    "/v1/ws",
    {
      websocket: true,
      // Issue #120: a single-use ticket is the only way in. The legacy `?token=<jwt>` handshake put
      // a bearer token in the URL (proxy/access logs, browser history) and bypassed parent-session
      // revocation. A stale client gets a JSON 401 that names the reason — the websocket plugin's
      // non-upgrade reply would be a 404 and look like a missing route.
      preValidation: async (req, reply) => {
        const query = (req.query ?? {}) as { ticket?: string; token?: string };
        if (query.token !== undefined || !query.ticket) {
          return reply.code(401).send({
            error: "ticket_required",
            message:
              "WebSocket connections require a single-use ticket: POST /v1/ws-ticket, then connect with ?ticket=<ticket>.",
          });
        }
      },
    },
    async (socket, req) => {
      try {
        const query = req.query as { ticket: string };
        // Single-use ticket: consumed on first presentment.
        const redis = getRedis();
        const raw = (await redis.get(`ws:ticket:${query.ticket}`).catch(() => null)) ?? "";
        // A ticket minted by an older process is the bare familyId string; accept both, so a deploy
        // mid-connection does not 4001 everybody.
        const parsed = raw.startsWith("{") ? (JSON.parse(raw) as { familyId?: string; parentId?: string | null }) : { familyId: raw, parentId: null };
        const familyId = parsed.familyId ?? "";
        if (!familyId) throw new Error("invalid ticket");
        await redis.del(`ws:ticket:${query.ticket}`).catch(() => {});
        const set = socketsByFamily.get(familyId) ?? new Set();
        set.add(socket);
        socketGates.set(socket, await gateFor(parsed.parentId ?? null));
        socketsByFamily.set(familyId, set);
        socket.on("close", () => set.delete(socket));
        // TR-05: tell the client its subscription is live. Until this frame arrives the client has
        // no way to know whether a `family:*:events` message published after `open` reached it — the
        // registration above happens only after the ticket's Redis GET+DEL, so `open` fires early.
        // Contract: `ready` is the FIRST frame on every socket, it carries the familyId the socket is
        // bound to, and no event frame is sent before it. Harnesses wait for it; the parent app can
        // use it to end a reconnect spinner. Sent after the set add, so a message that races the
        // send is delivered on this socket (the subscriber iterates the set it was just added to).
        // `familyId` is deliberate (TR-05 review): the holder authenticated as that family's parent
        // and already has the id; it lets a client assert which family the stream is bound to. Add
        // NOTHING else — no child id, device id or ticket — this frame reaches devtools and proxy logs.
        sendFrame(socket, { type: "ready", familyId, ts: new Date().toISOString() });
      } catch {
        socket.close(4001, "unauthorized");
      }
    },
  );

  subscriber.psubscribe("family:*:events");
  subscriber.on("pmessage", (_pattern, channel, message) => {
    const familyId = channel.split(":")[1];
    const type = frameType(message);
    const set = socketsByFamily.get(familyId);
    // #350: `listening: false` is "nobody is subscribed to this family" — a different fact from
    // `listening: true, written: 0, sockets: 2`, which is "two sockets were here and neither was open".
    if (!set) {
      gatewayLog?.info({ familyId, type, listening: false, written: 0, sockets: 0 }, "realtime fan-out");
      return;
    }
    let written = 0;
    // ADR-0014 amendment, decision 3 (second half, #402): a frame this socket may not read is not sent.
    // `type` is already parsed above for the log line; an unknown type is never withheld, so a new event
    // is open by default rather than silently dropped.
    const needed = EVENT_PERMISSION[type];
    for (const ws of set) {
      if (ws.readyState === 1) {
        const gate = socketGates.get(ws);
        if (needed && gate?.guardian && !gate.allowed.has(needed)) continue;
        ws.send(message);
        written += 1;
      }
    }
    // `sockets` is the set's size and `written` what actually left; a CLOSING/CLOSED socket is counted
    // in the first and not the second, which is the gap that makes a miss look like a delivery.
    gatewayLog?.info({ familyId, type, listening: true, written, sockets: set.size }, "realtime fan-out");
  });
}

export async function publishFamilyEvent(familyId: string, event: unknown) {
  // Review API-4: reuse the shared lazy publisher instead of opening a connection per event.
  // #350: `publish` resolves to the number of Redis clients that received the message, and that number is
  // the whole point of this line — `receivers: 0` says the event went nowhere while the route still
  // answered 201, which is the state the 2026-10-23 investigation could not read off the log.
  const receivers = await getRedis().publish(`family:${familyId}:events`, JSON.stringify(event));
  gatewayLog?.info({ familyId, type: eventType(event), receivers }, "realtime publish");
  return receivers;
}
