import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { createRequire } from "node:module";
import { Writable } from "node:stream";
import Fastify, { type FastifyInstance } from "fastify";
import fastifyJwt from "@fastify/jwt";
import fastifyWebsocket from "@fastify/websocket";
import { publishFamilyEvent, registerRealtime, subscriberErrorCount } from "../src/realtime/gateway.js";
import { getRedis } from "../src/redis.js";
import { MockRedis, prismaMock, resetPrismaMock } from "./helpers.js";

// #402: the gateway reads the subscriber's parent row; the default caller is an owner (never withheld).
vi.mock("../src/db.js", async () => {
  const { prismaMock } = await import("./helpers.js");
  return { prisma: prismaMock };
});

vi.mock("ioredis", async () => {
  const { MockRedis } = await import("./helpers.js");
  return { Redis: MockRedis };
});

// Same resolution as test/realtime.test.ts: the `ws` client ships inside @fastify/websocket.
const require = createRequire(import.meta.url);
const WebSocket = require(require.resolve("ws", { paths: [require.resolve("@fastify/websocket")] })) as typeof import("ws");

/**
 * Issue #350 asks for evidence a reviewer can read, so the assertions here read the **serialised pino
 * lines** the Fastify logger actually wrote, not a spy on a method. A line that is never emitted, or is
 * emitted with the field renamed, fails these tests the way it would fail the investigation.
 */
async function listen(): Promise<{
  app: FastifyInstance;
  base: string;
  lines: Array<Record<string, any>>;
}> {
  const lines: Array<Record<string, any>> = [];
  const stream = new Writable({
    write(chunk, _enc, cb) {
      for (const raw of String(chunk).split("\n")) {
        if (!raw.trim()) continue;
        try {
          lines.push(JSON.parse(raw) as Record<string, any>);
        } catch {
          // pino wrote a fragment; the tests only read whole JSON lines.
        }
      }
      cb();
    },
  });
  const app = Fastify({ logger: { level: "info", stream } });
  await app.register(fastifyJwt, { secret: "test-secret" });
  await app.register(fastifyWebsocket);
  registerRealtime(app);
  await app.listen({ port: 0, host: "127.0.0.1" });
  const addr = app.server.address() as { port: number };
  return { app, base: `127.0.0.1:${addr.port}`, lines };
}

/** Collect the frames a client socket receives, and its close code. */
function connect(url: string) {
  const ws = new WebSocket(url);
  const frames: Array<Record<string, unknown>> = [];
  let closeCode: number | null = null;
  ws.on("message", (data) => frames.push(JSON.parse(data.toString())));
  ws.on("close", (code) => { closeCode = code; });
  ws.on("error", () => {});
  const waitFor = (pred: () => boolean, ms = 3000) =>
    new Promise<void>((resolve, reject) => {
      const t0 = Date.now();
      const tick = () => {
        if (pred()) return resolve();
        if (Date.now() - t0 > ms) return reject(new Error(`timeout; frames=${JSON.stringify(frames)} close=${closeCode}`));
        setTimeout(tick, 10);
      };
      tick();
    });
  return { ws, frames, close: () => closeCode, waitFor };
}

/** The gateway's pmessage handler, registered on the dedicated subscriber at module load. */
function pmessageHandler(): (pattern: string, channel: string, message: string) => void {
  const sub = MockRedis.instances.find((r) => r.psubscribe.mock.calls.length > 0);
  if (!sub) throw new Error("gateway subscriber not found");
  const call = sub.on.mock.calls.find((c) => c[0] === "pmessage");
  if (!call) throw new Error("pmessage handler not registered");
  return call[1] as (pattern: string, channel: string, message: string) => void;
}

describe("realtime gateway — publish and fan-out evidence (#350)", () => {
  let app: FastifyInstance;
  let base: string;
  let lines: Array<Record<string, any>>;
  const store = new Map<string, string>();

  const logsOf = (msg: string) => lines.filter((l) => l.msg === msg);
  const PUBLISH = "realtime publish";
  const FANOUT = "realtime fan-out";

  /** Consume a ticket and wait for `ready`, so the socket is in the family's set. */
  async function openSocket(familyId: string) {
    // osra-security#4: the socket re-checks that the parent still belongs to this family on every frame, so
    // the fixture has to answer for the family the socket is being opened for.
    prismaMock.parent.findUnique.mockResolvedValue({
      role: "owner",
      familyId,
    });
    const token = app.jwt.sign({ sub: "parent-1", familyId, role: "parent" });
    const t = await app.inject({ method: "POST", url: "/v1/ws-ticket", headers: { authorization: `Bearer ${token}` } });
    expect(t.statusCode).toBe(200);
    const c = connect(`ws://${base}/v1/ws?ticket=${encodeURIComponent(t.json().ticket as string)}`);
    await c.waitFor(() => c.frames.length >= 1);
    expect(c.frames[0]).toMatchObject({ type: "ready", familyId });
    return c;
  }

  beforeEach(async () => {
    store.clear();
    resetPrismaMock();
    const redis = getRedis() as unknown as MockRedis;
    // The mock is module-scoped (one instance per test file), so call history carries over between tests.
    redis.publish.mockClear();
    redis.publish.mockResolvedValue(1);
    redis.get.mockImplementation(async (k: string) => store.get(k) ?? null);
    redis.set.mockImplementation(async (k: string, v: string) => { store.set(k, String(v)); return "OK"; });
    redis.del.mockImplementation(async (...ks: string[]) => ks.reduce((n, k) => n + (store.delete(k) ? 1 : 0), 0));
    ({ app, base, lines } = await listen());
  });
  afterEach(async () => { await app.close(); });

  // Mutant: log a constant (say `receivers: 1`) instead of `publish()`'s return value -> this test's
  // `receivers` is 1, not 0, and it fails. The case is the one that cost the investigation: a 201 on the
  // route, no frame on the socket, and nothing in the log to say the event reached no one.
  it("logs a publish with no receivers as receivers: 0", async () => {
    const redis = getRedis() as unknown as MockRedis;
    redis.publish.mockResolvedValueOnce(0);

    const receivers = await publishFamilyEvent("fam-1", {
      type: "alert",
      payload: { title: "a title that must not be logged" },
      ts: "2026-10-24T00:00:00.000Z",
    });

    expect(receivers).toBe(0);
    const [line] = logsOf(PUBLISH);
    expect(line).toBeDefined();
    expect(line).toMatchObject({ familyId: "fam-1", type: "alert" });
    expect(line!.receivers).toBe(0);
    // #350 rule 4: no payload, no ticket, no address — only the family, the type and the count.
    expect(JSON.stringify(line)).not.toContain("a title that must not be logged");
    const fields = Object.keys(line!).filter((k) => !["level", "time", "pid", "hostname", "msg"].includes(k)).sort();
    expect(fields).toEqual(["familyId", "receivers", "type"]);
  });

  // Mutant: same constant -> `receivers` is 1 while `publish()` returned 3, and this fails. Mutant:
  // drop the log line -> `logsOf(PUBLISH)` is empty, and this fails.
  it("logs publish()'s own count: three receivers are logged as three", async () => {
    const redis = getRedis() as unknown as MockRedis;
    redis.publish.mockResolvedValueOnce(3);

    const receivers = await publishFamilyEvent("fam-1", { type: "location", payload: { lat: 1 } });

    expect(receivers).toBe(3);
    expect(redis.publish).toHaveBeenCalledTimes(1);
    const [line] = logsOf(PUBLISH);
    expect(line).toMatchObject({ familyId: "fam-1", type: "location", receivers: 3 });
  });

  // Mutant: log `set.size` for `written` -> the third case (0 of 2) reports written: 2 and fails. Mutant:
  // drop the `if (!set)` branch's line -> the first case's line is missing and fails.
  it("distinguishes 'nobody listening' from 'wrote 0 of 2'", async () => {
    const pmessage = pmessageHandler();

    // 1. No set for the family at all: nobody has ever subscribed to it.
    pmessage("family:*:events", "family:fam-none:events", JSON.stringify({ type: "alert", payload: {} }));
    expect(logsOf(FANOUT).at(-1)).toMatchObject({
      familyId: "fam-none", type: "alert", listening: false, written: 0, sockets: 0,
    });

    // 2. Two sockets, both still in the set, neither open: a real close would remove them, so put them in
    //    CLOSING through the server-side socket the gateway holds. `ws.close()` sets readyState to 2
    //    synchronously and the server's `close` event — the removal — lands a tick later, after this line.
    const c1 = await openSocket("fam-2");
    const c2 = await openSocket("fam-2");
    const serverSockets = [...((app as unknown as { websocketServer: { clients: Set<{ close: () => void }> } })
      .websocketServer.clients)];
    expect(serverSockets).toHaveLength(2);
    for (const s of serverSockets) s.close();
    pmessage("family:*:events", "family:fam-2:events", JSON.stringify({ type: "alert", payload: {} }));
    await new Promise((r) => setTimeout(r, 50));
    expect(logsOf(FANOUT).at(-1)).toMatchObject({
      familyId: "fam-2", type: "alert", listening: true, written: 0, sockets: 2,
    });
    // Nothing was written: both clients still hold only their `ready` frame.
    expect(c1.frames.map((f) => f.type)).toEqual(["ready"]);
    expect(c2.frames.map((f) => f.type)).toEqual(["ready"]);

    // 3. One open socket: written 1 of 1, so the two zeros above are distinguishable from a success.
    const c3 = await openSocket("fam-3");
    pmessage("family:*:events", "family:fam-3:events", JSON.stringify({ type: "alert", payload: { id: 1 } }));
    await new Promise((r) => setTimeout(r, 50));
    expect(logsOf(FANOUT).at(-1)).toMatchObject({
      familyId: "fam-3", type: "alert", listening: true, written: 1, sockets: 1,
    });
    await c3.waitFor(() => c3.frames.length >= 2);
    c1.ws.close();
    c2.ws.close();
    c3.ws.close();
  });

  // Mutant: restore `subscriber.on("error", () => {})` -> no warn line and the count stays put, so both
  // assertions fail. The error handler is the one that was silent by construction, so it is the one that
  // has to be shown working.
  it("logs a subscriber error at warn and keeps a count instead of swallowing it", async () => {
    const sub = MockRedis.instances.find((r) => r.psubscribe.mock.calls.length > 0);
    const call = sub?.on.mock.calls.find((c) => c[0] === "error");
    expect(call).toBeDefined();
    const onError = call![1] as (err: Error) => void;
    const before = subscriberErrorCount();

    onError(new Error("subscribe failed"));

    const [line] = logsOf("realtime subscriber error (ioredis reconnects; sockets unchanged)");
    expect(line).toBeDefined();
    expect(line!.level).toBe(40); // pino: warn
    expect(line!.subscriberErrors).toBe(before + 1);
    expect((line!.err as { message: string }).message).toBe("subscribe failed");
    expect(subscriberErrorCount()).toBe(before + 1);
  });
});
