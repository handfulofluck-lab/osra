import { beforeEach, describe, expect, it, vi } from "vitest";
import { deviceRoutes } from "../src/routes/devices.js";
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

const DEVICE = { id: "dev-1", childId: "child-1", child: { familyId: "fam-1" } };

describe("device command queue", () => {
  beforeEach(() => {
    resetPrismaMock();
  });

  it("publishes {type, payload} to the device channel and persists a pending command row", async () => {
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

    expect(res.json()).toMatchObject({ published: true, status: "pending", deviceId: "dev-1" });
    expect(typeof res.json().id).toBe("string");
    const redis = getRedis() as unknown as import("./helpers.js").MockRedis;
    expect(redis.publish).toHaveBeenCalledWith("device:dev-1:commands", expect.stringContaining('"type":"ring"'));
    expect(prismaMock.deviceCommand.create).toHaveBeenCalledWith(
      expect.objectContaining({ data: expect.objectContaining({ deviceId: "dev-1", type: "ring", requestedBy: "parent-1", expiresAt: expect.any(Date) }) }),
    );
    await app.close();
  });

  it("GET /commands claims pending rows for the device JWT only and returns [{type,payload,...}]", async () => {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    prismaMock.device.findUnique.mockResolvedValue(DEVICE);
    const t = new Date("2026-10-16T10:00:00Z");
    // The drain is one UPDATE … RETURNING, so two concurrent drains cannot both receive a row.
    prismaMock.$queryRaw.mockResolvedValue([
      { id: "c1", deviceId: "dev-1", type: "lock", payload: {}, status: "delivered", createdAt: t, expiresAt: new Date(t.getTime() + 86400000), attempts: 1 },
    ]);

    const parent = await app.inject({ method: "GET", url: "/v1/devices/dev-1/commands", headers: authHeader(app) });
    expect(parent.statusCode).toBe(403); // probe note B11: a parent token must not consume the queue

    const otherDevice = await app.inject({ method: "GET", url: "/v1/devices/dev-1/commands", headers: deviceHeader(app, { deviceId: "dev-9", childId: "child-1", familyId: "fam-1" }) });
    expect(otherDevice.statusCode).toBe(403);

    const res = await app.inject({ method: "GET", url: "/v1/devices/dev-1/commands", headers: deviceHeader(app) });
    expect(res.statusCode).toBe(200);
    expect(res.json()).toEqual([
      { id: "c1", deviceId: "dev-1", type: "lock", payload: {}, ts: t.toISOString(), expiresAt: new Date(t.getTime() + 86400000).toISOString(), attempt: 1 },
    ]);
    expect(prismaMock.$executeRaw).toHaveBeenCalled(); // expired sweep
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

  // Issue #138: enrollment creates device credentials, so it requires the same `devices`
  // permission as command, push-token and unpair. A guardian invited with `[]` used to mint a
  // Device row (and, via pair/claim, its HMAC signing key) while being refused `command`.
  it("register requires the devices permission: co-parent without it 403, with it 201", async () => {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    prismaMock.child.findUnique.mockResolvedValue({ id: "child-1", familyId: "fam-1" });
    prismaMock.device.create.mockResolvedValue({ id: "dev-2", childId: "child-1", platform: "android" });
    const payload = { childId: "child-1", platform: "android", model: "Pixel 7a", osVersion: "14" };

    prismaMock.parent.findUnique.mockResolvedValue({ id: "p-co", familyId: "fam-1", role: "co-parent", permissions: ["location"] });
    const denied = await app.inject({
      method: "POST",
      url: "/v1/devices/register",
      headers: authHeader(app, "fam-1", "p-co"),
      payload,
    });
    expect(denied.statusCode).toBe(403);
    expect(denied.json()).toEqual({ error: "permission_required", permission: "devices" });
    expect(prismaMock.child.findUnique).not.toHaveBeenCalled();
    expect(prismaMock.device.create).not.toHaveBeenCalled();

    prismaMock.parent.findUnique.mockResolvedValue({ id: "p-co", familyId: "fam-1", role: "co-parent", permissions: ["devices"] });
    const allowed = await app.inject({
      method: "POST",
      url: "/v1/devices/register",
      headers: authHeader(app, "fam-1", "p-co"),
      payload,
    });
    expect(allowed.statusCode).toBe(201);
    expect(allowed.json().device.id).toBe("dev-2");
    await app.close();
  });

  // Issue #138: /register returned the raw Prisma row — the internalSecret column (the per-device
  // HMAC key; null at enrollment, minted at claim) and any pushToken — through a route no
  // sanitizeDevice call covered.
  it("register response is sanitized: no internalSecret, no pushToken", async () => {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    prismaMock.child.findUnique.mockResolvedValue({ id: "child-1", familyId: "fam-1" });
    prismaMock.device.create.mockResolvedValue({
      id: "dev-2",
      childId: "child-1",
      platform: "android",
      internalSecret: "per-device-hmac-secret",
      pushToken: "fcm-token",
    });

    const res = await app.inject({
      method: "POST",
      url: "/v1/devices/register",
      headers: authHeader(app),
      payload: { childId: "child-1", platform: "android", model: "Pixel 7a", osVersion: "14" },
    });
    expect(res.statusCode).toBe(201);
    expect(res.json().device.id).toBe("dev-2");
    expect(res.json().device).not.toHaveProperty("internalSecret");
    expect(res.json().device).not.toHaveProperty("pushToken");
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
    // Keyed, not `mockResolvedValueOnce`: session liveness (and now the epoch check in
    // requireFamily) reads Redis before the telemetry key does.
    redis.get.mockImplementation(async (k: string) =>
      k === "device:dev-1:telemetry" ? JSON.stringify({ batteryPct: 55, receivedAt: "2026-09-15T00:00:00Z" }) : null,
    );

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
    expect(prismaMock.device.update).toHaveBeenCalledWith(expect.objectContaining({
      where: { id: "dev-1" },
      data: { pushToken: "fcm-new" },
    }));
    // Audit finding 6: the row is read through an allowlist, so a secret column added later is not
    // returned by accident either.
    const select = prismaMock.device.update.mock.calls[0][0].select as Record<string, boolean>;
    expect(select).toBeDefined();
    expect(select).not.toHaveProperty("internalSecret");
    expect(select).not.toHaveProperty("pushToken");
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

  // Audit finding 6: the update returns the whole Prisma row, so the response used to carry the
  // per-device HMAC `internalSecret` (and the push token) to any parent who set a token.
  it("push-token response is sanitized: no internalSecret, no pushToken", async () => {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    prismaMock.device.findUnique.mockResolvedValue(DEVICE);
    prismaMock.device.update.mockResolvedValue({ ...DEVICE, pushToken: "fcm-new", internalSecret: "per-device-hmac-secret" });

    const res = await app.inject({
      method: "POST",
      url: "/v1/devices/dev-1/push-token",
      headers: authHeader(app),
      payload: { pushToken: "fcm-new" },
    });
    expect(res.statusCode).toBe(200);
    expect(res.json().device).not.toHaveProperty("internalSecret");
    expect(res.json().device).not.toHaveProperty("pushToken");
    expect(res.json().device.id).toBe("dev-1");
    await app.close();
  });

  // Audit finding 6: command and unpair require the `devices` permission; push-token now matches.
  it("push-token requires the devices permission: a co-parent without it is rejected (403)", async () => {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    prismaMock.parent.findUnique.mockResolvedValue({ id: "p-co", familyId: "fam-1", role: "co-parent", permissions: ["location"] });
    prismaMock.device.findUnique.mockResolvedValue(DEVICE);

    const denied = await app.inject({
      method: "POST",
      url: "/v1/devices/dev-1/push-token",
      headers: authHeader(app, "fam-1", "p-co"),
      payload: { pushToken: "fcm-new" },
    });
    expect(denied.statusCode).toBe(403);
    expect(denied.json()).toEqual({ error: "permission_required", permission: "devices" });
    expect(prismaMock.device.findUnique).not.toHaveBeenCalled();
    expect(prismaMock.device.update).not.toHaveBeenCalled();

    prismaMock.parent.findUnique.mockResolvedValue({ id: "p-co", familyId: "fam-1", role: "co-parent", permissions: ["devices"] });
    prismaMock.device.update.mockResolvedValue({ ...DEVICE, pushToken: "fcm-new" });
    const allowed = await app.inject({
      method: "POST",
      url: "/v1/devices/dev-1/push-token",
      headers: authHeader(app, "fam-1", "p-co"),
      payload: { pushToken: "fcm-new" },
    });
    expect(allowed.statusCode).toBe(200);
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

  it("issue #221: stores the location grant a device reports, and leaves it alone when omitted", async () => {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    prismaMock.device.findUnique.mockResolvedValue(DEVICE);
    prismaMock.device.update.mockResolvedValue(DEVICE);

    const reported = await app.inject({
      method: "POST",
      url: "/v1/devices/dev-1/telemetry",
      headers: deviceHeader(app),
      payload: { batteryPct: 44, locationGrant: "while_in_use" },
    });
    expect(reported.statusCode).toBe(202);
    expect(prismaMock.device.update).toHaveBeenLastCalledWith(
      expect.objectContaining({ where: { id: "dev-1" }, data: expect.objectContaining({ locationGrant: "while_in_use" }) }),
    );

    // An older agent (or any upload that omits the field) must not erase the stored grant.
    const omitted = await app.inject({
      method: "POST",
      url: "/v1/devices/dev-1/telemetry",
      headers: deviceHeader(app),
      payload: { batteryPct: 43 },
    });
    expect(omitted.statusCode).toBe(202);
    const data = prismaMock.device.update.mock.calls.at(-1)![0].data;
    expect(data).not.toHaveProperty("locationGrant");
    await app.close();
  });

  it("rejects an unknown location grant on telemetry (400)", async () => {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    prismaMock.device.findUnique.mockResolvedValue(DEVICE);
    const res = await app.inject({
      method: "POST",
      url: "/v1/devices/dev-1/telemetry",
      headers: deviceHeader(app),
      payload: { locationGrant: "always" },
    });
    expect(res.statusCode).toBe(400);
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

  // Audit finding 5: `requireFamily` proves the device belongs to the caller's family, not that the
  // caller *is* it. Device A could refresh sibling B's lastSeen/status and write B's usage.
  it("telemetry: a device token may post only for its own id (403 to a sibling), parents stay family-scoped", async () => {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    prismaMock.device.findUnique.mockImplementation(async ({ where }: { where: { id: string } }) =>
      where.id === "dev-1" ? DEVICE : { ...DEVICE, id: "dev-2" });
    prismaMock.device.update.mockResolvedValue(DEVICE);

    const sibling = await app.inject({
      method: "POST",
      url: "/v1/devices/dev-1/telemetry",
      headers: deviceHeader(app, { deviceId: "dev-2", childId: "child-1", familyId: "fam-1" }),
      payload: { batteryPct: 10 },
    });
    expect(sibling.statusCode).toBe(403);
    expect(prismaMock.device.update).not.toHaveBeenCalled();

    const own = await app.inject({
      method: "POST",
      url: "/v1/devices/dev-1/telemetry",
      headers: deviceHeader(app),
      payload: { batteryPct: 10 },
    });
    expect(own.statusCode).toBe(202);

    for (const url of ["/v1/devices/dev-1/telemetry", "/v1/devices/dev-2/telemetry"]) {
      const parent = await app.inject({ method: "POST", url, headers: authHeader(app), payload: { batteryPct: 10 } });
      expect(parent.statusCode).toBe(202);
    }

    prismaMock.device.findUnique.mockResolvedValue({ ...DEVICE, child: { familyId: "fam-2" } });
    const foreign = await app.inject({
      method: "POST",
      url: "/v1/devices/dev-1/telemetry",
      headers: deviceHeader(app, { deviceId: "dev-2", childId: "child-1", familyId: "fam-1" }),
      payload: { batteryPct: 10 },
    });
    expect(foreign.statusCode).toBe(403);
    await app.close();
  });

  it("activity: a device token may post only for its own id (403 to a sibling), parents stay family-scoped", async () => {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    prismaMock.device.findUnique.mockImplementation(async ({ where }: { where: { id: string } }) =>
      where.id === "dev-1" ? DEVICE : { ...DEVICE, id: "dev-2" });
    prismaMock.activityEvent.createMany.mockResolvedValue({ count: 1 });
    // An app_usage event would publish a `live_activity` frame on success, so the 403 case can assert
    // that the frame is suppressed as well as the row.
    const batch = { events: [{ type: "app_usage", payload: { app: "YouTube", minutes: 5 } }] };
    const redis = getRedis() as unknown as import("./helpers.js").MockRedis;
    redis.publish.mockClear();

    const sibling = await app.inject({
      method: "POST",
      url: "/v1/devices/dev-1/activity",
      headers: deviceHeader(app, { deviceId: "dev-2", childId: "child-1", familyId: "fam-1" }),
      payload: batch,
    });
    expect(sibling.statusCode).toBe(403);
    expect(prismaMock.activityEvent.createMany).not.toHaveBeenCalled();
    expect(redis.publish).not.toHaveBeenCalledWith("family:fam-1:events", expect.any(String));

    const own = await app.inject({
      method: "POST",
      url: "/v1/devices/dev-1/activity",
      headers: deviceHeader(app),
      payload: batch,
    });
    expect(own.statusCode).toBe(202);
    expect(redis.publish).toHaveBeenCalledWith("family:fam-1:events", expect.stringContaining('"live_activity"'));

    for (const url of ["/v1/devices/dev-1/activity", "/v1/devices/dev-2/activity"]) {
      const parent = await app.inject({ method: "POST", url, headers: authHeader(app), payload: batch });
      expect(parent.statusCode).toBe(202);
    }

    prismaMock.device.findUnique.mockResolvedValue({ ...DEVICE, child: { familyId: "fam-2" } });
    const foreign = await app.inject({
      method: "POST",
      url: "/v1/devices/dev-1/activity",
      headers: authHeader(app, "fam-1"),
      payload: batch,
    });
    expect(foreign.statusCode).toBe(403);
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

  it("issue #31: accumulates daily screen time minutes on telemetry reports", async () => {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    prismaMock.device.findUnique.mockResolvedValue({ ...DEVICE, childId: "child-1" });
    prismaMock.device.update.mockResolvedValue(DEVICE);

    const today = new Date().toISOString().slice(0, 10);
    const redis = MockRedis.instances[MockRedis.instances.length - 1];

    const res = await app.inject({
      method: "POST",
      url: "/v1/devices/dev-1/telemetry",
      headers: deviceHeader(app),
      payload: { totalMinutes: 15 },
    });
    expect(res.statusCode).toBe(202);
    expect(redis.incrby).toHaveBeenCalledWith(`usage:child:child-1:${today}`, 15);
    expect(redis.expire).toHaveBeenCalledWith(`usage:child:child-1:${today}`, 86400 * 2);
    await app.close();
  });
});

