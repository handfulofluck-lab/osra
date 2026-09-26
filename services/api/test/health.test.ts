import { beforeEach, describe, expect, it, vi } from "vitest";
import { healthRoutes } from "../src/routes/health.js";
import { MockRedis, buildApp, prismaMock, resetPrismaMock } from "./helpers.js";

vi.mock("../src/db.js", async () => {
  const { prismaMock } = await import("./helpers.js");
  return { prisma: prismaMock };
});
vi.mock("ioredis", async () => {
  const { MockRedis } = await import("./helpers.js");
  return { Redis: MockRedis };
});

describe("health routes", () => {
  beforeEach(() => {
    resetPrismaMock();
    // NOTE: redis.ts caches its client across tests, so instances[] is not
    // reset here — always address the most recent instance.
  });

  it("/health returns ok without touching dependencies", async () => {
    const app = await buildApp(healthRoutes, "");
    const res = await app.inject({ method: "GET", url: "/health" });
    expect(res.statusCode).toBe(200);
    expect(res.json()).toEqual({ ok: true, version: "0.1.0" });
    expect(prismaMock.$queryRaw).not.toHaveBeenCalled();
    await app.close();
  });

  it("/health/deep reports up when db and redis respond", async () => {
    const app = await buildApp(healthRoutes, "");
    const res = await app.inject({ method: "GET", url: "/health/deep" });
    expect(res.statusCode).toBe(200);
    expect(res.json()).toEqual({ ok: true, version: "0.1.0", db: "up", redis: "up" });
    await app.close();
  });

  it("/health/deep returns 503 naming the dependency that is down", async () => {
    const app = await buildApp(healthRoutes, "");
    // Simulate a Postgres outage (the failure mode that surfaces as login 500s).
    prismaMock.$queryRaw.mockRejectedValue(new Error("Can't reach database server"));
    const res = await app.inject({ method: "GET", url: "/health/deep" });
    expect(res.statusCode).toBe(503);
    expect(res.json().db).toBe("down");
    expect(res.json().redis).toBe("up");
    await app.close();
  });

  it("/health/deep reports redis down when ping fails", async () => {
    const app = await buildApp(healthRoutes, "");
    // First request forces getRedis() to create (and cache) the mocked instance.
    await app.inject({ method: "GET", url: "/health/deep" });
    const redis = MockRedis.instances[MockRedis.instances.length - 1];
    redis.ping.mockRejectedValue(new Error("Connection refused"));
    const res = await app.inject({ method: "GET", url: "/health/deep" });
    expect(res.statusCode).toBe(503);
    expect(res.json().db).toBe("up");
    expect(res.json().redis).toBe("down");
    await app.close();
  });
});
