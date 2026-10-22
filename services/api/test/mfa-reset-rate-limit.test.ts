import { beforeEach, describe, expect, it, vi } from "vitest";
import Fastify from "fastify";
import fastifyJwt from "@fastify/jwt";
import rateLimit from "@fastify/rate-limit";
import { authRoutes } from "../src/routes/auth.js";
import { registerErrorHandler } from "../src/lib/errorHandler.js";
import { prismaMock, resetPrismaMock } from "./helpers.js";

vi.mock("../src/db.js", async () => {
  const { prismaMock } = await import("./helpers.js");
  return { prisma: prismaMock };
});
vi.mock("ioredis", async () => {
  const { MockRedis } = await import("./helpers.js");
  return { Redis: MockRedis };
});
// Only the bucket is under test here; the password work is covered by test/mfa-reset.test.ts.
vi.mock("argon2", () => ({
  default: { verify: vi.fn(async () => false), hash: vi.fn(async () => "argon2$stub") },
}));

/**
 * ADR-0031 claim 1a: `/mfa/reset/request` has the same rate limit as `/login`.
 *
 * Registered the way `src/server.ts` registers them: the plugin-level bucket for `/v1/auth` and the
 * per-route `RL` config. Twenty requests pass the limiter, the twenty-first is refused — for both
 * routes, with the same statuses in the same order.
 */
async function buildRateLimitedApp() {
  const app = Fastify({ logger: false });
  await app.register(fastifyJwt, { secret: "test-secret" });
  await app.register(rateLimit, { max: 200, timeWindow: "1 minute" });
  registerErrorHandler(app);
  await app.register(authRoutes, { prefix: "/v1/auth", config: { rateLimit: { max: 20, timeWindow: "1 minute" } } });
  await app.ready();
  return app;
}

const burst = async (app: Awaited<ReturnType<typeof buildRateLimitedApp>>, url: string) => {
  const statuses: number[] = [];
  for (let i = 0; i < 21; i++) {
    const res = await app.inject({ method: "POST", url, payload: { email: "nobody@example.com", password: "WrongPassword123!" } });
    statuses.push(res.statusCode);
  }
  return statuses;
};

describe("MFA reset request — same rate limit as /login (ADR-0031 claim 1a)", () => {
  beforeEach(() => resetPrismaMock());

  it("both routes allow twenty requests a minute and refuse the twenty-first", async () => {
    const app = await buildRateLimitedApp();
    const login = await burst(app, "/v1/auth/login");
    const reset = await burst(app, "/v1/auth/mfa/reset/request");

    expect(login.slice(0, 20).every((s) => s === 401)).toBe(true);
    expect(login[20]).toBe(429);
    expect(reset.slice(0, 20).every((s) => s === 401)).toBe(true);
    expect(reset[20]).toBe(429);
    expect(reset).toEqual(login);
    await app.close();
  });
});
