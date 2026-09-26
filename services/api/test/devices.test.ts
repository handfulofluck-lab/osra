import { beforeEach, describe, expect, it, vi } from "vitest";
import { deviceRoutes } from "../src/routes/devices.js";
import { getRedis } from "../src/redis.js";
import { authHeader, buildApp, deviceHeader, prismaMock, resetPrismaMock } from "./helpers.js";

vi.mock("../src/db.js", async () => {
  const { prismaMock } = await import("./helpers.js");
  return { prisma: prismaMock };
});
vi.mock("ioredis", async () => {
  const { MockRedis } = await import("./helpers.js");
  return { Redis: MockRedis };
});

const DEVICE = { id: "dev-1", childId: "child-1", child: { familyId: "fam-1" } };

describe("device command queue", () => {
  beforeEach(() => {
    resetPrismaMock();
  });

  it("publishes {type, payload} to the device channel and pushes onto the polled queue", async () => {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    prismaMock.device.findUnique.mockResolvedValue(DEVICE);

    const res = await app.inject({
      method: "POST",
      url: "/v1/devices/dev-1/command",
      headers: authHeader(app),
      payload: { command: "ring" },
    });
    expect(res.statusCode).toBe(200);
    expect(res.json().type).toBe("ring");

    const redis = getRedis() as unknown as import("./helpers.js").MockRedis;
    expect(redis.publish).toHaveBeenCalledWith("device:dev-1:commands", expect.stringContaining('"type":"ring"'));
    expect(redis.lpush).toHaveBeenCalledWith("device:dev-1:command-queue", expect.stringContaining('"payload"'));
    await app.close();
  });

  it("GET /commands drains the queue and returns the pending commands", async () => {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    prismaMock.device.findUnique.mockResolvedValue(DEVICE);
    const queued = [JSON.stringify({ deviceId: "dev-1", type: "lock", payload: {}, ts: "t" })];
    const redis = getRedis() as unknown as import("./helpers.js").MockRedis;
    // The drain is atomic via Lua (LRANGE+DEL in one script).
    redis.eval.mockResolvedValue(queued);

    const res = await app.inject({
      method: "GET",
      url: "/v1/devices/dev-1/commands",
      headers: authHeader(app),
    });
    expect(res.statusCode).toBe(200);
    expect(res.json()).toEqual([{ deviceId: "dev-1", type: "lock", payload: {}, ts: "t" }]);
    expect(redis.eval).toHaveBeenCalled();
    await app.close();
  });

  it("returns 403 when another family tries to command the device", async () => {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    prismaMock.device.findUnique.mockResolvedValue({ ...DEVICE, child: { familyId: "fam-2" } });

    const res = await app.inject({
      method: "POST",
      url: "/v1/devices/dev-1/command",
      headers: authHeader(app, "fam-1"),
      payload: { command: "lock" },
    });
    expect(res.statusCode).toBe(403);
    await app.close();
  });

  it("rejects an unknown command with 400", async () => {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    prismaMock.device.findUnique.mockResolvedValue(DEVICE);

    const res = await app.inject({
      method: "POST",
      url: "/v1/devices/dev-1/command",
      headers: authHeader(app),
      payload: { command: "self_destruct" },
    });
    expect(res.statusCode).toBe(400);
    await app.close();
  });

  it("accepts the world-class command types (pause_internet, resume_internet, bonus_time, wind_down)", async () => {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    prismaMock.device.findUnique.mockResolvedValue(DEVICE);

    for (const command of ["pause_internet", "resume_internet", "bonus_time", "wind_down"]) {
      const res = await app.inject({
        method: "POST",
        url: "/v1/devices/dev-1/command",
        headers: authHeader(app),
        payload: { command, payload: { minutes: 30 } },
      });
      expect(res.statusCode).toBe(200);
      expect(res.json().type).toBe(command);
    }
    await app.close();
  });
});

describe("device enrollment & management", () => {
  beforeEach(() => {
    resetPrismaMock();
  });

  it("registers a device for a child of the family (201)", async () => {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    prismaMock.child.findUnique.mockResolvedValue({ id: "child-1", familyId: "fam-1" });
    prismaMock.device.create.mockResolvedValue({ id: "dev-2", childId: "child-1", platform: "android" });

    const res = await app.inject({
      method: "POST",
      url: "/v1/devices/register",
      headers: authHeader(app),
      payload: { childId: "child-1", platform: "android", model: "Pixel 7a", osVersion: "14", pushToken: "tok" },
    });
    expect(res.statusCode).toBe(201);
    expect(res.json().device.id).toBe("dev-2");
    expect(prismaMock.device.create).toHaveBeenCalledWith({
      data: { childId: "child-1", platform: "android", model: "Pixel 7a", osVersion: "14", pushToken: "tok" },
    });
    await app.close();
  });

  it("rejects register with an invalid body (400)", async () => {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    const badPlatform = await app.inject({
      method: "POST",
      url: "/v1/devices/register",
      headers: authHeader(app),
      payload: { childId: "child-1", platform: "toaster", model: "Pixel 7a", osVersion: "14" },
    });
    expect(badPlatform.statusCode).toBe(400);

    const missingFields = await app.inject({
      method: "POST",
      url: "/v1/devices/register",
      headers: authHeader(app),
      payload: { childId: "child-1" },
    });
    expect(missingFields.statusCode).toBe(400);
    expect(prismaMock.device.create).not.toHaveBeenCalled();
    await app.close();
  });

  it("returns 403 when registering for a foreign or missing child", async () => {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    prismaMock.child.findUnique.mockResolvedValue({ id: "child-1", familyId: "fam-2" });
    const foreign = await app.inject({
      method: "POST",
      url: "/v1/devices/register",
      headers: authHeader(app, "fam-1"),
      payload: { childId: "child-1", platform: "android", model: "Pixel 7a", osVersion: "14" },
    });
    expect(foreign.statusCode).toBe(403);

    // A missing child also returns 403 (no resource enumeration).
    prismaMock.child.findUnique.mockResolvedValue(null);
    const missing = await app.inject({
      method: "POST",
      url: "/v1/devices/register",
      headers: authHeader(app, "fam-1"),
      payload: { childId: "child-9", platform: "android", model: "Pixel 7a", osVersion: "14" },
    });
    expect(missing.statusCode).toBe(403);
    expect(prismaMock.device.create).not.toHaveBeenCalled();
    await app.close();
  });

  it("rejects device tokens on register (403) — parent-only mutation", async () => {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    const res = await app.inject({
      method: "POST",
      url: "/v1/devices/register",
      headers: deviceHeader(app),
      payload: { childId: "child-1", platform: "android", model: "Pixel 7a", osVersion: "14" },
    });
    expect(res.statusCode).toBe(403);
    expect(prismaMock.child.findUnique).not.toHaveBeenCalled();
    await app.close();
  });

  it("lists the family's devices scoped by family (200), 401 without a token", async () => {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    prismaMock.device.findMany.mockResolvedValue([{ id: "dev-1" }, { id: "dev-2" }]);

    const res = await app.inject({ method: "GET", url: "/v1/devices", headers: authHeader(app) });
    expect(res.statusCode).toBe(200);
    expect(res.json().devices).toHaveLength(2);
    expect(prismaMock.device.findMany).toHaveBeenCalledWith(
      expect.objectContaining({ where: { child: { familyId: "fam-1" } } }),
    );

    prismaMock.device.findMany.mockClear();
    const unauthenticated = await app.inject({ method: "GET", url: "/v1/devices" });
    expect(unauthenticated.statusCode).toBe(401);
    expect(prismaMock.device.findMany).not.toHaveBeenCalled();
    await app.close();
  });

  it("returns one device with its latest telemetry merged in (200), 404 for an unknown id", async () => {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    prismaMock.device.findUnique.mockResolvedValue(DEVICE);
    const redis = getRedis() as unknown as import("./helpers.js").MockRedis;
    redis.get.mockResolvedValueOnce(JSON.stringify({ batteryPct: 55, receivedAt: "2026-09-15T00:00:00Z" }));

    const res = await app.inject({ method: "GET", url: "/v1/devices/dev-1", headers: authHeader(app) });
    expect(res.statusCode).toBe(200);
    expect(res.json().device.id).toBe("dev-1");
    expect(res.json().telemetry.batteryPct).toBe(55);

    prismaMock.device.findUnique.mockResolvedValue(null);
    const missing = await app.inject({ method: "GET", url: "/v1/devices/dev-9", headers: authHeader(app) });
    expect(missing.statusCode).toBe(404);
    await app.close();
  });

  it("updates the push token as a parent (200)", async () => {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    prismaMock.device.findUnique.mockResolvedValue(DEVICE);
    prismaMock.device.update.mockResolvedValue({ ...DEVICE, pushToken: "fcm-new" });

    const res = await app.inject({
      method: "POST",
      url: "/v1/devices/dev-1/push-token",
      headers: authHeader(app),
      payload: { pushToken: "fcm-new" },
    });
    expect(res.statusCode).toBe(200);
    expect(prismaMock.device.update).toHaveBeenCalledWith({
      where: { id: "dev-1" },
      data: { pushToken: "fcm-new" },
    });
    await app.close();
  });

  it("rejects push-token updates from device tokens (403) and empty tokens (400)", async () => {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    const deviceToken = await app.inject({
      method: "POST",
      url: "/v1/devices/dev-1/push-token",
      headers: deviceHeader(app),
      payload: { pushToken: "fcm-new" },
    });
    expect(deviceToken.statusCode).toBe(403);
    expect(prismaMock.device.findUnique).not.toHaveBeenCalled();

    prismaMock.device.findUnique.mockResolvedValue(DEVICE);
    const empty = await app.inject({
      method: "POST",
      url: "/v1/devices/dev-1/push-token",
      headers: authHeader(app),
      payload: { pushToken: "" },
    });
    expect(empty.statusCode).toBe(400);
    expect(prismaMock.device.update).not.toHaveBeenCalled();
    await app.close();
  });

  it("rejects telemetry with an out-of-range battery or wrong field types (400)", async () => {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    prismaMock.device.findUnique.mockResolvedValue(DEVICE);

    const cases: unknown[] = [
      { batteryPct: 150 },
      { batteryPct: -1 },
      { batteryPct: "80" },
      { appUsage: [{ packageId: "com.game", minutes: "a lot" }] },
      { appUsage: [{ minutes: 5 }] },
      { urls: "https://example.com" },
    ];
    for (const payload of cases) {
      const res = await app.inject({
        method: "POST",
        url: "/v1/devices/dev-1/telemetry",
        headers: deviceHeader(app),
        payload: payload as Record<string, unknown>,
      });
      expect(res.statusCode).toBe(400);
    }
    expect(prismaMock.device.update).not.toHaveBeenCalled();
    await app.close();
  });

  it("rejects telemetry for another family's device (403)", async () => {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    prismaMock.device.findUnique.mockResolvedValue({ ...DEVICE, child: { familyId: "fam-2" } });

    const res = await app.inject({
      method: "POST",
      url: "/v1/devices/dev-1/telemetry",
      headers: authHeader(app, "fam-1"),
      payload: { batteryPct: 50 },
    });
    expect(res.statusCode).toBe(403);
    expect(prismaMock.device.update).not.toHaveBeenCalled();
    await app.close();
  });

  it("unenrolls a device (200), 403 for device tokens, 404 for an unknown id", async () => {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    prismaMock.device.findUnique.mockResolvedValue(DEVICE);
    prismaMock.device.delete.mockResolvedValue(DEVICE);

    const res = await app.inject({ method: "DELETE", url: "/v1/devices/dev-1", headers: authHeader(app) });
    expect(res.statusCode).toBe(200);
    expect(res.json()).toEqual({ deleted: true, id: "dev-1" });
    expect(prismaMock.device.delete).toHaveBeenCalledWith({ where: { id: "dev-1" } });

    prismaMock.device.findUnique.mockClear();
    const deviceToken = await app.inject({ method: "DELETE", url: "/v1/devices/dev-1", headers: deviceHeader(app) });
    expect(deviceToken.statusCode).toBe(403);
    expect(prismaMock.device.findUnique).not.toHaveBeenCalled();

    prismaMock.device.findUnique.mockResolvedValue(null);
    const missing = await app.inject({ method: "DELETE", url: "/v1/devices/dev-9", headers: authHeader(app) });
    expect(missing.statusCode).toBe(404);
    await app.close();
  });
});
