import { describe, expect, it } from "vitest";
import Fastify from "fastify";
import type { Redis } from "ioredis";
import {
  AUTH_RATE_LIMIT,
  PAIR_CLAIM_RATE_LIMIT,
  RATE_LIMIT_KEY_PREFIX,
  registerRateLimits,
  trustProxyFromEnv,
} from "../src/lib/rateLimits.js";
import { registerErrorHandler } from "../src/lib/errorHandler.js";
import { FakeRateLimitRedis } from "./helpers.js";

/**
 * Plan 2.7: rate limits key on the client address behind the load balancer, count in Redis so every
 * API task shares them, and fail open (global) or closed (auth, pairing claim) when Redis is down.
 *
 * The apps below are wired with the production pieces (`trustProxyFromEnv`, `registerRateLimits`, the
 * three bucket configs, `registerErrorHandler`); only the routes are stand-ins. `inject` arrives from
 * 127.0.0.1, which plays the ALB: the client address is the `X-Forwarded-For` entry the ALB appends.
 */

async function buildApp(redis: FakeRateLimitRedis, trustProxy: number | false = trustProxyFromEnv("1")) {
  const app = Fastify({ logger: false, trustProxy });
  await registerRateLimits(app, redis as unknown as Redis);
  registerErrorHandler(app);
  app.get("/open", async () => ({ ok: true }));
  app.post("/auth", { config: { rateLimit: AUTH_RATE_LIMIT } }, async () => ({ ok: true }));
  app.post("/claim", { config: { rateLimit: PAIR_CLAIM_RATE_LIMIT } }, async () => ({ ok: true }));
  await app.ready();
  return app;
}

type App = Awaited<ReturnType<typeof buildApp>>;
const from = (app: App, method: "GET" | "POST", url: string, xff?: string) =>
  app.inject({ method, url, headers: xff ? { "x-forwarded-for": xff } : {} });

describe("trustProxyFromEnv", () => {
  it("is a hop count, and trusts nothing when unset", () => {
    expect(trustProxyFromEnv(undefined)).toBe(false);
    expect(trustProxyFromEnv("")).toBe(false);
    expect(trustProxyFromEnv(" 1 ")).toBe(1);
    expect(trustProxyFromEnv("2")).toBe(2);
  });

  it("refuses `true` and anything else that is not a hop count", () => {
    // `true` would trust the leftmost X-Forwarded-For entry, which the caller writes.
    for (const bad of ["true", "yes", "10.0.0.0/8", "-1", "1.5"]) {
      expect(() => trustProxyFromEnv(bad)).toThrow(/TRUST_PROXY must be a hop count/);
    }
  });
});

describe("rate limits behind one proxy hop (plan 2.7)", () => {
  it("gives two client addresses behind the same proxy separate buckets", async () => {
    const app = await buildApp(new FakeRateLimitRedis());
    for (let i = 0; i < AUTH_RATE_LIMIT.max; i++) {
      expect((await from(app, "POST", "/auth", "198.51.100.7")).statusCode).toBe(200);
    }
    expect((await from(app, "POST", "/auth", "198.51.100.7")).statusCode).toBe(429);
    const other = await from(app, "POST", "/auth", "203.0.113.9");
    expect(other.statusCode).toBe(200);
    expect(other.headers["x-ratelimit-remaining"]).toBe(String(AUTH_RATE_LIMIT.max - 1));
    await app.close();
  });

  it("does not let a caller choose its bucket with extra X-Forwarded-For entries", async () => {
    const app = await buildApp(new FakeRateLimitRedis());
    // The caller writes everything left of the entry the ALB appends; rotating it changes nothing.
    for (let i = 0; i < AUTH_RATE_LIMIT.max; i++) {
      expect((await from(app, "POST", "/auth", `192.0.2.${i}, 198.51.100.7`)).statusCode).toBe(200);
    }
    expect((await from(app, "POST", "/auth", "192.0.2.250, 198.51.100.7")).statusCode).toBe(429);
    expect((await from(app, "POST", "/auth", "198.51.100.7")).statusCode).toBe(429);
    await app.close();
  });

  it("without TRUST_PROXY, X-Forwarded-For is ignored and everyone behind the proxy shares one bucket", async () => {
    // The state before this change, kept as a test so the setting's purpose stays visible.
    const app = await buildApp(new FakeRateLimitRedis(), trustProxyFromEnv(undefined));
    for (let i = 0; i < AUTH_RATE_LIMIT.max; i++) await from(app, "POST", "/auth", "198.51.100.7");
    expect((await from(app, "POST", "/auth", "203.0.113.9")).statusCode).toBe(429);
    await app.close();
  });

  it("limits pairing claims to ten a minute per client address", async () => {
    const app = await buildApp(new FakeRateLimitRedis());
    const statuses: number[] = [];
    for (let i = 0; i < 11; i++) statuses.push((await from(app, "POST", "/claim", "198.51.100.7")).statusCode);
    expect(statuses.slice(0, 10).every((s) => s === 200)).toBe(true);
    expect(statuses[10]).toBe(429);
    expect((await from(app, "POST", "/claim", "203.0.113.9")).statusCode).toBe(200);
    await app.close();
  });

  it("shares the count between two API instances on the same Redis", async () => {
    const redis = new FakeRateLimitRedis();
    const [a, b] = [await buildApp(redis), await buildApp(redis)];
    for (let i = 0; i < PAIR_CLAIM_RATE_LIMIT.max / 2; i++) {
      expect((await from(a, "POST", "/claim", "198.51.100.7")).statusCode).toBe(200);
      expect((await from(b, "POST", "/claim", "198.51.100.7")).statusCode).toBe(200);
    }
    expect((await from(a, "POST", "/claim", "198.51.100.7")).statusCode).toBe(429);
    expect((await from(b, "POST", "/claim", "198.51.100.7")).statusCode).toBe(429);
    expect([...redis.counts.keys()].every((k) => k.startsWith(RATE_LIMIT_KEY_PREFIX))).toBe(true);
    await Promise.all([a.close(), b.close()]);
  });

  it("with Redis down, the global bucket lets requests through and the auth and claim buckets refuse", async () => {
    const redis = new FakeRateLimitRedis();
    redis.down = true;
    const app = await buildApp(redis);
    expect((await from(app, "GET", "/open", "198.51.100.7")).statusCode).toBe(200);
    const auth = await from(app, "POST", "/auth", "198.51.100.7");
    const claim = await from(app, "POST", "/claim", "198.51.100.7");
    // Refused with 503 and no driver message (src/lib/errorHandler.ts), never served.
    for (const res of [auth, claim]) {
      expect(res.statusCode).toBe(503);
      expect(res.json()).toEqual({ error: "temporarily_unavailable" });
    }
    await app.close();
  });
});
