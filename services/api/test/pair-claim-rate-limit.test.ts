import { describe, expect, it, vi } from "vitest";
import Fastify from "fastify";
import fastifyJwt from "@fastify/jwt";
import type { Redis } from "ioredis";
import { deviceRoutes } from "../src/routes/devices.js";
import { registerRateLimits, trustProxyFromEnv } from "../src/lib/rateLimits.js";
import { registerErrorHandler } from "../src/lib/errorHandler.js";
import { FakeRateLimitRedis } from "./helpers.js";

vi.mock("../src/db.js", async () => {
  const { prismaMock } = await import("./helpers.js");
  return { prisma: prismaMock };
});
vi.mock("ioredis", async () => {
  const { MockRedis } = await import("./helpers.js");
  return { Redis: MockRedis };
});

/**
 * Plan 2.7 (#376): the real `POST /v1/devices/pair/claim` keeps its own bucket of 10 a minute.
 *
 * test/rate-limits.test.ts proves the bucket configs on stand-in routes; this registers the real
 * `deviceRoutes`, the way `src/server.ts` does, so a change that drops `PAIR_CLAIM_RATE_LIMIT` from the
 * route fails CI (the probe's S1 is the live check, but CI does not run the probe). The bodies are
 * malformed, so each claim stops at the schema (400) and no code is looked up.
 */
describe("POST /v1/devices/pair/claim — its own rate limit (plan 2.7)", () => {
  it("answers ten malformed claims from one address with 400, then 429 with x-ratelimit-limit 10", async () => {
    const app = Fastify({ logger: false, trustProxy: trustProxyFromEnv("1") });
    await app.register(fastifyJwt, { secret: "test-secret" });
    await registerRateLimits(app, new FakeRateLimitRedis() as unknown as Redis);
    registerErrorHandler(app);
    await app.register(deviceRoutes, { prefix: "/v1/devices" });
    await app.ready();

    const claim = (xff: string) =>
      app.inject({ method: "POST", url: "/v1/devices/pair/claim", headers: { "x-forwarded-for": xff }, payload: { code: "not-a-code" } });
    const responses = [];
    for (let i = 0; i < 11; i++) responses.push(await claim("198.51.100.7"));

    expect(responses.slice(0, 10).map((r) => r.statusCode)).toEqual(Array(10).fill(400));
    expect(responses[10].statusCode).toBe(429);
    expect(responses[10].headers["x-ratelimit-limit"]).toBe("10");
    expect((await claim("203.0.113.9")).statusCode).toBe(400); // another address has its own bucket
    await app.close();
  });
});
