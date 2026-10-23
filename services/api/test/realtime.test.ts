import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { createRequire } from "node:module";
import Fastify, { type FastifyInstance } from "fastify";
import fastifyJwt from "@fastify/jwt";
import fastifyWebsocket from "@fastify/websocket";
import { registerRealtime } from "../src/realtime/gateway.js";
import { getRedis } from "../src/redis.js";
import { MockRedis } from "./helpers.js";

vi.mock("ioredis", async () => {
  const { MockRedis } = await import("./helpers.js");
  return { Redis: MockRedis };
});

// The `ws` client is a transitive dependency of @fastify/websocket; resolve it from there so the
// test needs no extra devDependency and does not depend on Node 20's flagged global WebSocket.
const require = createRequire(import.meta.url);
const WebSocket = require(require.resolve("ws", { paths: [require.resolve("@fastify/websocket")] })) as typeof import("ws");

/** Real sockets need a listening server; `app.inject` cannot upgrade a connection. */
async function listen(): Promise<{ app: FastifyInstance; base: string }> {
  const app = Fastify({ logger: false });
  await app.register(fastifyJwt, { secret: "test-secret" });
  await app.register(fastifyWebsocket);
  registerRealtime(app);
  await app.listen({ port: 0, host: "127.0.0.1" });
  const addr = app.server.address() as { port: number };
  return { app, base: `127.0.0.1:${addr.port}` };
}

/** Collect frames (and the close event) from a client socket, in arrival order. */
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

/** The gateway's dedicated subscriber is the MockRedis on which psubscribe was called. */
function subscriberPmessageHandler(): (pattern: string, channel: string, message: string) => void {
  const sub = MockRedis.instances.find((r) => r.psubscribe.mock.calls.length > 0);
  if (!sub) throw new Error("gateway subscriber not found");
  const call = sub.on.mock.calls.find((c) => c[0] === "pmessage");
  if (!call) throw new Error("pmessage handler not registered");
  return call[1] as (pattern: string, channel: string, message: string) => void;
}

describe("realtime gateway — `ready` frame contract (TR-05)", () => {
  let app: FastifyInstance;
  let base: string;
  const store = new Map<string, string>();

  beforeEach(async () => {
    store.clear();
    const redis = getRedis() as unknown as MockRedis;
    redis.get.mockImplementation(async (k: string) => store.get(k) ?? null);
    redis.set.mockImplementation(async (k: string, v: string) => { store.set(k, String(v)); return "OK"; });
    redis.del.mockImplementation(async (...ks: string[]) => ks.reduce((n, k) => n + (store.delete(k) ? 1 : 0), 0));
    ({ app, base } = await listen());
  });
  afterEach(async () => { await app.close(); });

  it("sends {type:'ready', familyId, ts} as the FIRST frame right after the ticket is consumed", async () => {
    const token = app.jwt.sign({ sub: "parent-1", familyId: "fam-1", role: "parent" });
    const t = await app.inject({ method: "POST", url: "/v1/ws-ticket", headers: { authorization: `Bearer ${token}` } });
    expect(t.statusCode).toBe(200);
    const ticket = t.json().ticket as string;
    expect(store.get(`ws:ticket:${ticket}`)).toBe("fam-1");

    const c = connect(`ws://${base}/v1/ws?ticket=${encodeURIComponent(ticket)}`);
    await c.waitFor(() => c.frames.length >= 1);
    expect(c.frames[0]).toMatchObject({ type: "ready", familyId: "fam-1" });
    expect(typeof c.frames[0].ts).toBe("string");
    expect(Number.isNaN(Date.parse(c.frames[0].ts as string))).toBe(false);
    // Single use: the ticket is gone once the socket is registered.
    expect(store.has(`ws:ticket:${ticket}`)).toBe(false);
    c.ws.close();
  });

  it("delivers a family event AFTER ready, and only to that family's sockets", async () => {
    const token = app.jwt.sign({ sub: "parent-1", familyId: "fam-1", role: "parent" });
    const ticket = (await app.inject({ method: "POST", url: "/v1/ws-ticket", headers: { authorization: `Bearer ${token}` } })).json().ticket as string;
    const c = connect(`ws://${base}/v1/ws?ticket=${encodeURIComponent(ticket)}`);
    await c.waitFor(() => c.frames.length >= 1);

    const pmessage = subscriberPmessageHandler();
    pmessage("family:*:events", "family:fam-OTHER:events", JSON.stringify({ type: "alert", payload: { title: "not mine" } }));
    pmessage("family:*:events", "family:fam-1:events", JSON.stringify({ type: "alert", payload: { title: "mine" } }));
    await c.waitFor(() => c.frames.length >= 2);
    expect(c.frames.map((f) => f.type)).toEqual(["ready", "alert"]);
    expect((c.frames[1].payload as { title: string }).title).toBe("mine");
    c.ws.close();
  });

  it("closes an invalid ticket with 4001 and never sends ready", async () => {
    const c = connect(`ws://${base}/v1/ws?ticket=${encodeURIComponent("nope-" + Date.now())}`);
    await c.waitFor(() => c.close() !== null);
    expect(c.close()).toBe(4001);
    expect(c.frames).toEqual([]);
  });

  // Issue #120: the legacy `?token=<jwt>` handshake is removed. A stale client must get a
  // JSON 401 that names the reason, not a silent 404 (the websocket plugin's non-upgrade reply).
  it("refuses a parent JWT in the query string with HTTP 401 ticket_required", async () => {
    const token = app.jwt.sign({ sub: "parent-1", familyId: "fam-1", role: "parent" });
    const res = await app.inject({ method: "GET", url: `/v1/ws?token=${encodeURIComponent(token)}` });
    expect(res.statusCode).toBe(401);
    expect(res.json()).toMatchObject({ error: "ticket_required" });
  });

  it("refuses a device JWT in the query string with HTTP 401 ticket_required", async () => {
    const token = app.jwt.sign({ sub: "dev-1", deviceId: "dev-1", childId: "child-1", familyId: "fam-1", role: "device" });
    const res = await app.inject({ method: "GET", url: `/v1/ws?token=${encodeURIComponent(token)}` });
    expect(res.statusCode).toBe(401);
    expect(res.json()).toMatchObject({ error: "ticket_required" });
  });

  // Plan 2.7 Q4 (Claude, #329, 2026-10-23): a purpose-scoped token is not a bearer credential (#146).
  // Before the fix it reached the role check and got 403 parent_role_required; now it is 401 like
  // every other route. A purpose token that also carries role "parent" is the case the role check
  // alone would have let through, so it is the one that proves the order of the checks.
  it("refuses a purpose-scoped token at /v1/ws-ticket with 401 unauthorized, and mints no ticket", async () => {
    for (const purpose of ["password_reset", "mfa_recovery", "mfa_reset_confirm", "mfa_reset_cancel"]) {
      for (const claims of [{ sub: "parent-1", purpose }, { sub: "parent-1", familyId: "fam-1", role: "parent", purpose }]) {
        const token = app.jwt.sign(claims);
        const res = await app.inject({ method: "POST", url: "/v1/ws-ticket", headers: { authorization: `Bearer ${token}` } });
        expect(res.statusCode).toBe(401);
        expect(res.json()).toEqual({ error: "unauthorized" });
      }
    }
    expect([...store.keys()].some((k) => k.startsWith("ws:ticket:"))).toBe(false);
  });

  // Plan 2.7 F5 (Claude, #329): the ticket opens the family's live socket, so ws-ticket checks the
  // parent's sessions version itself — this harness registers no global hook. Before F5 the stale token
  // got a ticket (200). Mutant: delete the isParentSessionLive check in gateway.ts -> 200.
  it("refuses a parent whose session was revoked (401 session_revoked) and mints no ticket", async () => {
    store.set("auth:session-version:parent-1", "2");
    const stale = app.jwt.sign({ sub: "parent-1", familyId: "fam-1", role: "parent", jti: "c".repeat(32), sv: 1 });
    const res = await app.inject({ method: "POST", url: "/v1/ws-ticket", headers: { authorization: `Bearer ${stale}` } });
    expect(res.statusCode).toBe(401);
    expect(res.json()).toEqual({ error: "session_revoked" });
    expect([...store.keys()].some((k) => k.startsWith("ws:ticket:"))).toBe(false);

    const current = app.jwt.sign({ sub: "parent-1", familyId: "fam-1", role: "parent", jti: "d".repeat(32), sv: 2 });
    const ok = await app.inject({ method: "POST", url: "/v1/ws-ticket", headers: { authorization: `Bearer ${current}` } });
    expect(ok.statusCode).toBe(200);
  });

  it("refuses a handshake with no ticket with HTTP 401 ticket_required", async () => {
    const res = await app.inject({ method: "GET", url: "/v1/ws" });
    expect(res.statusCode).toBe(401);
    expect(res.json()).toMatchObject({ error: "ticket_required" });
  });
});
