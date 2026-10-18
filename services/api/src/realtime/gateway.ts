import { randomUUID } from "node:crypto";
import type { FastifyInstance } from "fastify";
import { Redis } from "ioredis";
import { getRedis } from "../redis.js";

// The gateway needs a DEDICATED subscriber connection (psubscribe switches a connection
// into subscriber mode); publishing reuses the shared lazy publisher via getRedis().
const subscriber = new Redis(process.env.REDIS_URL ?? "redis://localhost:6379");
subscriber.on("error", () => {});
const socketsByFamily = new Map<string, Set<any>>();

/** Serialise and send one frame if the socket is still open; a closed socket is not an error. */
function sendFrame(socket: { readyState: number; send: (data: string) => void }, frame: unknown) {
  if (socket.readyState === 1) socket.send(JSON.stringify(frame));
}

export function registerRealtime(app: FastifyInstance) {
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
    const user = req.user as { role?: string; familyId?: string; deviceId?: string };
    if (user.role === "device" && user.deviceId) {
      const revoked = await getRedis().get(`revoked:device:${user.deviceId}`).catch(() => null);
      if (revoked) {
        return reply.code(401).send({ error: "device_revoked" });
      }
    }
    if (user.role !== "parent") {
      return reply.code(403).send({ error: "parent_role_required" });
    }
    const ticket = randomUUID();
    const familyId = user.familyId ?? "";
    await getRedis().set(`ws:ticket:${ticket}`, familyId, "EX", 60);
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
        const familyId = (await redis.get(`ws:ticket:${query.ticket}`).catch(() => null)) ?? "";
        if (!familyId) throw new Error("invalid ticket");
        await redis.del(`ws:ticket:${query.ticket}`).catch(() => {});
        const set = socketsByFamily.get(familyId) ?? new Set();
        set.add(socket);
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
    const set = socketsByFamily.get(familyId);
    if (!set) return;
    for (const ws of set) if (ws.readyState === 1) ws.send(message);
  });
}

export async function publishFamilyEvent(familyId: string, event: unknown) {
  // Review API-4: reuse the shared lazy publisher instead of opening a connection per event.
  await getRedis().publish(`family:${familyId}:events`, JSON.stringify(event));
}
