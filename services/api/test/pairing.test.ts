import { beforeEach, describe, expect, it, vi } from "vitest";
import Fastify, { type FastifyInstance } from "fastify";
import fastifyJwt from "@fastify/jwt";
import { deviceRoutes } from "../src/routes/devices.js";
import { rulesRoutes } from "../src/routes/rules.js";
import { familyRoutes } from "../src/routes/family.js";
import { locationRoutes } from "../src/routes/location.js";
import { getRedis } from "../src/redis.js";
import { MockRedis, authHeader, buildApp, deviceHeader, prismaMock, resetPrismaMock } from "./helpers.js";

vi.mock("../src/db.js", async () => {
  const { prismaMock } = await import("./helpers.js");
  return { prisma: prismaMock };
});
vi.mock("ioredis", async () => {
  const { MockRedis } = await import("./helpers.js");
  return { Redis: MockRedis };
});

/** In-memory Redis state so pair/claim round-trips behave like a real store. */
const store = new Map<string, string>();

function wireRedis(): MockRedis {
  const redis = getRedis() as unknown as MockRedis;
  redis.get.mockImplementation(async (key: string) => store.get(key) ?? null);
  redis.set.mockImplementation(async (key: string, value: unknown) => {
    store.set(key, String(value));
    return "OK";
  });
  redis.del.mockImplementation(async (...keys: string[]) =>
    keys.reduce((n, k) => n + (store.delete(k) ? 1 : 0), 0),
  );
  // Atomic consume, mirroring the production Lua GET+DEL script.
  redis.eval.mockImplementation(async (_script: string, _n: number, key: string) => {
    const value = store.get(key) ?? null;
    if (value !== null) store.delete(key);
    return value;
  });
  redis.publish.mockResolvedValue(1);
  redis.lpush.mockResolvedValue(1);
  redis.ltrim.mockResolvedValue("OK");
  redis.lrange.mockResolvedValue([]);
  return redis;
}

/** Build one app with every route family mounted, mirroring server.ts wiring. */
async function buildFullApp(): Promise<FastifyInstance> {
  const app = Fastify({ logger: false });
  await app.register(fastifyJwt, { secret: "test-secret" });
  await app.register(deviceRoutes, { prefix: "/v1/devices" });
  await app.register(rulesRoutes, { prefix: "/v1/rules" });
  await app.register(familyRoutes, { prefix: "/v1/family" });
  await app.register(locationRoutes, { prefix: "/v1/location" });
  await app.ready();
  return app;
}

describe("device pairing (spec §14.1)", () => {
  beforeEach(() => {
    resetPrismaMock();
    store.clear();
    wireRedis();
  });

  it("POST /pair (parent JWT) returns a 6-digit code stored with a 600 s TTL", async () => {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    prismaMock.child.findUnique.mockResolvedValue({ id: "child-1", familyId: "fam-1" });

    const res = await app.inject({
      method: "POST",
      url: "/v1/devices/pair",
      headers: authHeader(app),
      payload: { childId: "child-1" },
    });
    expect(res.statusCode).toBe(201);
    const body = res.json();
    expect(body.code).toMatch(/^\d{6}$/);
    const ttlMs = new Date(body.expiresAt).getTime() - Date.now();
    expect(ttlMs).toBeGreaterThan(590_000);
    expect(ttlMs).toBeLessThanOrEqual(600_000);
    expect(store.get(`pair:${body.code}`)).toBe(JSON.stringify({ childId: "child-1", familyId: "fam-1" }));
    const redis = getRedis() as unknown as MockRedis;
    expect(redis.set).toHaveBeenCalledWith(
      `pair:${body.code}`,
      JSON.stringify({ childId: "child-1", familyId: "fam-1" }),
      "EX",
      600,
      "NX",
    );
    await app.close();
  });

  it("POST /pair returns 400 on a bad body and 403 for a child outside the family", async () => {
    const app = await buildApp(deviceRoutes, "/v1/devices");

    const bad = await app.inject({
      method: "POST",
      url: "/v1/devices/pair",
      headers: authHeader(app),
      payload: {},
    });
    expect(bad.statusCode).toBe(400);

    prismaMock.child.findUnique.mockResolvedValue({ id: "child-1", familyId: "fam-2" });
    const forbidden = await app.inject({
      method: "POST",
      url: "/v1/devices/pair",
      headers: authHeader(app, "fam-1"),
      payload: { childId: "child-1" },
    });
    expect(forbidden.statusCode).toBe(403);
    await app.close();
  });

  it("POST /pair rejects device tokens (403) — parent-only mutation", async () => {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    const res = await app.inject({
      method: "POST",
      url: "/v1/devices/pair",
      headers: deviceHeader(app),
      payload: { childId: "child-1" },
    });
    expect(res.statusCode).toBe(403);
    expect(res.json().error).toBe("parent_role_required");
    expect(prismaMock.child.findUnique).not.toHaveBeenCalled();
    await app.close();
  });

  it("POST /pair/claim creates the device from the Redis payload and mints a device JWT", async () => {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    store.set("pair:123456", JSON.stringify({ childId: "child-1", familyId: "fam-1" }));
    prismaMock.device.create.mockImplementation(async ({ data }: { data: Record<string, unknown> }) => ({
      id: "dev-9",
      ...data,
    }));

    const res = await app.inject({
      method: "POST",
      url: "/v1/devices/pair/claim",
      // No authorization header: claim runs before any credentials exist.
      payload: {
        code: "123456",
        platform: "android",
        model: "Pixel 7a",
        osVersion: "14",
        deviceName: "Alex's Phone",
        pushToken: "tok-1",
        // Client-supplied ids must be ignored — the server takes them from the Redis payload.
        childId: "evil-child",
        familyId: "fam-9",
      },
    });
    expect(res.statusCode).toBe(201);
    const body = res.json();
    expect(body.childId).toBe("child-1");
    expect(body.familyId).toBe("fam-1");
    expect(body.device.id).toBe("dev-9");
    expect(body.device.childId).toBe("child-1");
    expect(body.device.status).toBe("online");
    expect(body.device.model).toBe("Alex's Phone"); // deviceName wins over model
    expect(body.device).not.toHaveProperty("familyId");

    const decoded = app.jwt.verify<{ sub: string; deviceId: string; childId: string; familyId: string; role: string; exp?: number }>(
      body.token,
    );
    expect(decoded.role).toBe("device");
    expect(decoded.sub).toBe("dev-9");
    expect(decoded.deviceId).toBe("dev-9");
    expect(decoded.childId).toBe("child-1");
    expect(decoded.familyId).toBe("fam-1");
    expect(decoded.exp).toBeGreaterThan(Date.now() / 1000 + 9 * 365 * 86400); // ~10y validity

    // The code is consumed.
    const redis = getRedis() as unknown as MockRedis;
    expect(redis.eval).toHaveBeenCalled();
    expect(store.has("pair:123456")).toBe(false);
    await app.close();
  });

  it("claim returns the internal HMAC secret so agents can sign alerts (BUG-001)", async () => {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    store.set("pair:111111", JSON.stringify({ childId: "child-1", familyId: "fam-1" }));
    prismaMock.device.create.mockResolvedValue({ id: "dev-h", childId: "child-1" });
    const previous = process.env.INTERNAL_HMAC_SECRET;
    process.env.INTERNAL_HMAC_SECRET = "claim-secret-abc";

    const res = await app.inject({
      method: "POST",
      url: "/v1/devices/pair/claim",
      payload: { code: "111111", platform: "android", model: "Pixel", osVersion: "14" },
    });
    expect(res.statusCode).toBe(201);
    // Handoff item 5: the claim returns a freshly minted PER-DEVICE secret (64 hex chars),
    // never the global INTERNAL_HMAC_SECRET.
    const secret = res.json().hmacSecret;
    expect(secret).toMatch(/^[0-9a-f]{64}$/);
    expect(secret).not.toBe("claim-secret-abc");
    if (previous === undefined) delete process.env.INTERNAL_HMAC_SECRET;
    else process.env.INTERNAL_HMAC_SECRET = previous;
    await app.close();
  });

  it("concurrent claims of the same code: exactly one succeeds (BUG-005)", async () => {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    store.set("pair:222222", JSON.stringify({ childId: "child-1", familyId: "fam-1" }));
    let seq = 0;
    prismaMock.device.create.mockImplementation(async () => ({ id: `dev-${seq++}`, childId: "child-1" }));

    const [first, second] = await Promise.all([
      app.inject({
        method: "POST",
        url: "/v1/devices/pair/claim",
        payload: { code: "222222", platform: "android", model: "A", osVersion: "1" },
      }),
      app.inject({
        method: "POST",
        url: "/v1/devices/pair/claim",
        payload: { code: "222222", platform: "windows", model: "B", osVersion: "10" },
      }),
    ]);
    const statuses = [first.statusCode, second.statusCode].sort((a, b) => a - b);
    expect(statuses).toEqual([201, 404]); // one minted, one rejected
    expect(seq).toBe(1); // exactly one device created
    await app.close();
  });

  it("POST /pair/claim falls back to model when deviceName is absent", async () => {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    store.set("pair:654321", JSON.stringify({ childId: "child-1", familyId: "fam-1" }));
    prismaMock.device.create.mockImplementation(async ({ data }: { data: Record<string, unknown> }) => ({
      id: "dev-10",
      ...data,
    }));

    const res = await app.inject({
      method: "POST",
      url: "/v1/devices/pair/claim",
      payload: { code: "654321", platform: "windows", model: "Surface Go", osVersion: "11" },
    });
    expect(res.statusCode).toBe(201);
    expect(res.json().device.model).toBe("Surface Go");
    await app.close();
  });

  it("POST /pair/claim returns 400 for a malformed claim body", async () => {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    const badCode = await app.inject({
      method: "POST",
      url: "/v1/devices/pair/claim",
      payload: { code: "12345", platform: "android", model: "Pixel", osVersion: "14" },
    });
    expect(badCode.statusCode).toBe(400);

    const badPlatform = await app.inject({
      method: "POST",
      url: "/v1/devices/pair/claim",
      payload: { code: "123456", platform: "toaster", model: "Pixel", osVersion: "14" },
    });
    expect(badPlatform.statusCode).toBe(400);

    const missingFields = await app.inject({
      method: "POST",
      url: "/v1/devices/pair/claim",
      payload: { code: "123456" },
    });
    expect(missingFields.statusCode).toBe(400);
    expect(prismaMock.device.create).not.toHaveBeenCalled();
    await app.close();
  });

  it("POST /pair/claim returns 404 for an unknown or expired code", async () => {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    const res = await app.inject({
      method: "POST",
      url: "/v1/devices/pair/claim",
      payload: { code: "000000", platform: "android", model: "Pixel", osVersion: "14" },
    });
    expect(res.statusCode).toBe(404);
    expect(res.json().error).toBe("invalid_or_expired_code");
    expect(prismaMock.device.create).not.toHaveBeenCalled();
    await app.close();
  });

  it("POST /pair/claim rejects a second claim with the same code (consumed, 404)", async () => {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    store.set("pair:111222", JSON.stringify({ childId: "child-1", familyId: "fam-1" }));
    prismaMock.device.create.mockImplementation(async ({ data }: { data: Record<string, unknown> }) => ({
      id: "dev-11",
      ...data,
    }));
    const payload = { code: "111222", platform: "android", model: "Pixel", osVersion: "14" };

    const first = await app.inject({ method: "POST", url: "/v1/devices/pair/claim", payload });
    expect(first.statusCode).toBe(201);

    const second = await app.inject({ method: "POST", url: "/v1/devices/pair/claim", payload });
    expect(second.statusCode).toBe(404);
    expect(second.json().error).toBe("invalid_or_expired_code");
    expect(prismaMock.device.create).toHaveBeenCalledTimes(1);
    await app.close();
  });
});

describe("device JWT compatibility (spec §14.1)", () => {
  beforeEach(() => {
    resetPrismaMock();
    store.clear();
    wireRedis();
  });

  it("rejects device tokens (403) from POST /v1/family/children", async () => {
    const app = await buildFullApp();
    const res = await app.inject({
      method: "POST",
      url: "/v1/family/children",
      headers: deviceHeader(app),
      payload: { displayName: "Alex", birthYear: 2013 },
    });
    expect(res.statusCode).toBe(403);
    expect(res.json().error).toBe("parent_role_required");
    expect(prismaMock.child.create).not.toHaveBeenCalled();
    await app.close();
  });

  it("rejects device tokens (403) from PUT /v1/rules/:childId", async () => {
    const app = await buildFullApp();
    const res = await app.inject({
      method: "PUT",
      url: "/v1/rules/child-1",
      headers: deviceHeader(app),
      payload: {},
    });
    expect(res.statusCode).toBe(403);
    expect(res.json().error).toBe("parent_role_required");
    expect(prismaMock.ruleSet.upsert).not.toHaveBeenCalled();
    await app.close();
  });

  it("accepts device tokens (200) from GET /v1/rules/:childId", async () => {
    const app = await buildFullApp();
    prismaMock.child.findUnique.mockResolvedValue({ id: "child-1", familyId: "fam-1" });
    prismaMock.ruleSet.findUnique.mockResolvedValue(null);

    const res = await app.inject({
      method: "GET",
      url: "/v1/rules/child-1",
      headers: deviceHeader(app),
    });
    expect(res.statusCode).toBe(200);
    expect(res.json().childId).toBe("child-1");
    await app.close();
  });

  it("accepts device tokens (202) from POST /v1/devices/:id/telemetry", async () => {
    const app = await buildFullApp();
    prismaMock.device.findUnique.mockResolvedValue({ id: "dev-1", child: { familyId: "fam-1" } });

    const res = await app.inject({
      method: "POST",
      url: "/v1/devices/dev-1/telemetry",
      headers: deviceHeader(app),
      payload: { batteryPct: 80, appUsage: [{ packageId: "com.game", minutes: 12 }] },
    });
    expect(res.statusCode).toBe(202);
    expect(store.get("device:dev-1:telemetry")).toContain('"batteryPct":80');
    await app.close();
  });

  it("accepts device tokens (201) from POST /v1/location/ping", async () => {
    const app = await buildFullApp();
    prismaMock.child.findUnique.mockResolvedValue({ id: "child-1", familyId: "fam-1" });
    prismaMock.geofence.findMany.mockResolvedValue([]);
    prismaMock.locationPing.create.mockResolvedValue({ id: "ping-1" });

    const res = await app.inject({
      method: "POST",
      url: "/v1/location/ping",
      headers: deviceHeader(app),
      payload: { childId: "child-1", deviceId: "dev-1", lat: 40.7128, lng: -74.006, accuracyM: 5 },
    });
    expect(res.statusCode).toBe(201);
    expect(res.json().ping.id).toBe("ping-1");
    await app.close();
  });
});
