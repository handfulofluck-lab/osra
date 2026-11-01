import Fastify from "fastify";
import fastifyJwt from "@fastify/jwt";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { deviceRoutes } from "../src/routes/devices.js";
import { healthRoutes } from "../src/routes/health.js";
import { registerClientHeader } from "../src/middleware/clientHeader.js";
import { MockRedis, authHeader, deviceHeader, prismaMock, resetPrismaMock } from "./helpers.js";

vi.mock("../src/db.js", async () => {
  const { prismaMock } = await import("./helpers.js");
  return { prisma: prismaMock };
});
vi.mock("ioredis", async () => {
  const { MockRedis } = await import("./helpers.js");
  return { Redis: MockRedis };
});

/**
 * ADR-0034 PR 1b at the hook, not only in the library.
 *
 * `registerClientHeader` is the production hook, mounted here on a small app the way `sessionGuardHook` is
 * mounted elsewhere — `server.ts` listens on import and cannot be imported by a test.
 */

const DEVICE = { id: "dev-1", childId: "child-1", child: { familyId: "fam-1" } };

async function appWith(policy?: string) {
  const previous = process.env.CLIENT_POLICY;
  if (policy === undefined) delete process.env.CLIENT_POLICY;
  else process.env.CLIENT_POLICY = policy;
  const app = Fastify({ logger: false });
  await app.register(fastifyJwt, { secret: "test-secret" });
  registerClientHeader(app);
  await app.register(healthRoutes);
  await app.register(deviceRoutes, { prefix: "/v1/devices" });
  await app.ready();
  process.env.CLIENT_POLICY = previous;
  return app;
}

describe("claim 5 — with the policy empty, nothing is refused and everything is told `none`", () => {
  beforeEach(() => resetPrismaMock());

  it("a device route answers normally and carries X-OSRA-Update: none", async () => {
    const app = await appWith(undefined);
    prismaMock.device.findUnique.mockResolvedValue(DEVICE);
    prismaMock.device.update.mockResolvedValue(DEVICE);

    const res = await app.inject({
      method: "GET",
      url: "/v1/devices/dev-1",
      headers: { ...deviceHeader(app), "x-osra-client": "child-android/0.2.0+2 (full)" },
    });

    expect(res.statusCode).toBe(200);
    expect(res.headers["x-osra-update"]).toBe("none");
  });

  it("a malformed header is legacy, never a 400", async () => {
    // Decision 4/A3: anything not exactly the pattern is a client older than this change, and the server
    // answers it as today. Claude's f3 (a malformed header answered with 400) survived every row until
    // this one: the library row proved `parseClientHeader` returns null, and nothing proved the HOOK does
    // not refuse on the way in.
    const app = await appWith(undefined);
    prismaMock.device.findUnique.mockResolvedValue(DEVICE);
    prismaMock.device.update.mockResolvedValue(DEVICE);

    const res = await app.inject({
      method: "GET",
      url: "/v1/devices/dev-1",
      headers: { ...deviceHeader(app), "x-osra-client": "not-a-build/at-all" },
    });

    expect(res.statusCode).toBe(200);
    expect(res.headers["x-osra-update"]).toBe("none");
  });

  it("a legacy client is served exactly as today", async () => {
    const app = await appWith(undefined);
    prismaMock.device.findUnique.mockResolvedValue(DEVICE);
    prismaMock.device.update.mockResolvedValue(DEVICE);

    const res = await app.inject({ method: "GET", url: "/v1/devices/dev-1", headers: deviceHeader(app) });

    expect(res.statusCode).toBe(200);
    expect(res.headers["x-osra-update"]).toBe("none");
  });
});

describe("claims 5 and 12 — the gate, and the routes it must never touch", () => {
  beforeEach(() => resetPrismaMock());

  it("a parent below min is refused on a normal route with 426 update_required", async () => {
    const app = await appWith('{"parent-app":{"min":3}}');
    prismaMock.device.findMany.mockResolvedValue([]);

    const res = await app.inject({
      method: "GET",
      url: "/v1/devices",
      headers: { ...authHeader(app), "x-osra-client": "parent-app/0.1.0+2 (android)" },
    });

    expect(res.statusCode).toBe(426);
    expect(res.json()).toMatchObject({ error: "update_required", app: "parent-app", minBuild: 3 });
    expect(res.headers["x-osra-update"]).toBe("required");
  });

  it("claim 12 — /health still answers under the same gate", async () => {
    const app = await appWith('{"parent-app":{"min":3}}');

    const res = await app.inject({
      method: "GET",
      url: "/health",
      headers: { "x-osra-client": "parent-app/0.1.0+2 (android)" },
    });

    expect(res.statusCode).toBe(200);
    // The header still says the truth; the route is simply outside the gate.
    expect(res.headers["x-osra-update"]).toBe("required");
  });

  it("claim 6 (server half) — the child agent is never refused, even below min", async () => {
    const app = await appWith('{"child-android":{"min":5}}');
    prismaMock.device.findUnique.mockResolvedValue(DEVICE);
    prismaMock.device.update.mockResolvedValue(DEVICE);

    const res = await app.inject({
      method: "GET",
      url: "/v1/devices/dev-1",
      headers: { ...deviceHeader(app), "x-osra-client": "child-android/0.2.0+2 (full)" },
    });

    expect(res.statusCode).toBe(200);
    expect(res.headers["x-osra-update"]).toBe("required");
  });
});

describe("A3 / claim 10 — the build is written only by the device it belongs to", () => {
  beforeEach(() => resetPrismaMock());

  it("a device's own request records its build on its own row", async () => {
    const app = await appWith(undefined);
    prismaMock.device.findUnique.mockResolvedValue(DEVICE);
    prismaMock.device.update.mockResolvedValue(DEVICE);

    await app.inject({
      method: "GET",
      url: "/v1/devices/dev-1",
      headers: { ...deviceHeader(app), "x-osra-client": "child-android/0.2.0+7 (full)" },
    });

    expect(prismaMock.device.update).toHaveBeenCalledWith(
      expect.objectContaining({
        where: { id: "dev-1" },
        data: expect.objectContaining({ clientBuild: 7, clientApp: "child-android", clientFlavour: "full" }),
      }),
    );
  });

  it("claim 10 — a PARENT's request to the same device leaves the stored build alone", async () => {
    const app = await appWith(undefined);
    prismaMock.device.findUnique.mockResolvedValue(DEVICE);
    prismaMock.device.update.mockResolvedValue(DEVICE);

    await app.inject({
      method: "GET",
      url: "/v1/devices/dev-1",
      headers: { ...authHeader(app), "x-osra-client": "parent-app/0.9.0+9 (android)" },
    });

    const deviceWrites = prismaMock.device.update.mock.calls.map((c) => c[0]?.data ?? {});
    expect(deviceWrites.some((d) => d.clientBuild !== undefined)).toBe(false);
  });
});
