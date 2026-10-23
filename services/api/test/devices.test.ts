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
  // permission as command and unpair (push-token left this set in #319: it is device-only now). A
  // guardian invited with `[]` used to mint a Device row (and, via pair/claim, its HMAC signing key)
  // while being refused `command`.
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

  // ── #319 (Claude, 2026-10-23): the push-token write is device-only ─────────────────────────────
  // What this block used to assert is the opposite: a parent with the `devices` permission set a
  // token and got a sanitized device back (audit finding 6 / #124), a device token was refused, and
  // a second `/push-token/self` route carried the agent's own registration. The decision is that the
  // path stays `POST /:id/push-token` — so the Android client needs no change — and becomes
  // device-only: one token, one device, `204`, no body, no parent. The parent capability was removed
  // on purpose because it had no legitimate caller. Each test below names the decision that
  // superseded an older assertion, and the mutant that would break it.
  const SELF_TOKEN = "fcm-device-self-token-0001"; // 26 chars: inside the 20..4096 bounds
  const SIBLING_TOKEN = "fcm-device-sibling-token-0002";

  // MUTANT: answer `200 { ok: true }` instead of `204`, or drop the `prisma.device.update` from the
  // transaction — either fails this test (`expected 200 to be 204`; `expected "spy" to be called 1
  // times, but got 0 times`). Both measured, then reverted.
  it("a device JWT stores its own push token and answers 204 with no body", async () => {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    prismaMock.device.findUnique.mockResolvedValue(DEVICE);
    prismaMock.device.update.mockResolvedValue({ ...DEVICE, pushToken: SELF_TOKEN });

    const res = await app.inject({
      method: "POST",
      url: "/v1/devices/dev-1/push-token",
      headers: deviceHeader(app),
      payload: { token: SELF_TOKEN },
    });
    expect(res.statusCode).toBe(204);
    // Superseded: the parent route answered `200 { device }` and this file used to assert the
    // allowlisted `select` of that body. A 204 carries nothing — no device object, no token.
    expect(res.body).toBe("");
    expect(prismaMock.device.update).toHaveBeenCalledTimes(1);
    expect(prismaMock.device.update).toHaveBeenCalledWith({ where: { id: "dev-1" }, data: { pushToken: SELF_TOKEN } });
    await app.close();
  });

  // MUTANT: remove `requireOwnDevice()` and this returns 204: `requireFamily` only proves dev-1 is
  // in dev-2's family, so a sibling's token is written.
  it("refuses a sibling device id (403 forbidden) without writing anything", async () => {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    prismaMock.device.findUnique.mockResolvedValue(DEVICE);

    const res = await app.inject({
      method: "POST",
      url: "/v1/devices/dev-1/push-token",
      headers: deviceHeader(app, { deviceId: "dev-2", childId: "child-1", familyId: "fam-1" }),
      payload: { token: SIBLING_TOKEN },
    });
    expect(res.statusCode).toBe(403);
    expect(res.json()).toEqual({ error: "forbidden" });
    expect(prismaMock.device.update).not.toHaveBeenCalled();
    expect(prismaMock.device.updateMany).not.toHaveBeenCalled();
    await app.close();
  });

  // Superseded: this was two tests — "updates the push token as a parent (200)" and "push-token
  // requires the devices permission". #319 removed the parent capability, so both collapse into
  // "no parent may write it", and the owner case proves the refusal is about the role, not the
  // permission set.
  // MUTANT: drop `requireDeviceRole` from the preHandler — a parent token passes `requireOwnDevice`
  // untouched (it only refuses device tokens), the transaction runs and the answer is 204.
  it("refuses a parent session in the same family (403 device_role_required), with or without the devices permission", async () => {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    prismaMock.device.findUnique.mockResolvedValue(DEVICE);

    for (const permissions of [[], ["devices"]]) {
      prismaMock.parent.findUnique.mockResolvedValue({ id: "p-co", familyId: "fam-1", role: "co-parent", permissions });
      const res = await app.inject({
        method: "POST",
        url: "/v1/devices/dev-1/push-token",
        headers: authHeader(app, "fam-1", "p-co"),
        payload: { token: SELF_TOKEN },
      });
      expect(res.statusCode).toBe(403);
      expect(res.json().error).toBe("device_role_required");
    }

    // The owner of the family holds every permission; the refusal must not be permission-shaped.
    const owner = await app.inject({
      method: "POST",
      url: "/v1/devices/dev-1/push-token",
      headers: authHeader(app),
      payload: { token: SELF_TOKEN },
    });
    expect(owner.statusCode).toBe(403);
    expect(owner.json().error).toBe("device_role_required");

    expect(prismaMock.device.update).not.toHaveBeenCalled();
    expect(prismaMock.device.updateMany).not.toHaveBeenCalled();
    await app.close();
  });

  // One token, one device. The mock is made to hold two real rows so the test reads an *outcome*:
  // dev-1 registers a phone's token, then dev-2 (the same phone, re-paired) registers the same
  // token, and dev-1 must end up with none — otherwise the old row keeps waking a phone that now
  // belongs to someone else.
  // MUTANT: drop the `updateMany` from the transaction — dev-1 keeps the token and the last
  // assertion fails on `"fcm-device-self-token-0001"` instead of null.
  it("one token, one device: the same token re-posted by another device clears it from the first", async () => {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    const rows: Record<string, { id: string; pushToken: string | null }> = {
      "dev-1": { id: "dev-1", pushToken: null },
      "dev-2": { id: "dev-2", pushToken: null },
    };
    prismaMock.device.findUnique.mockImplementation(async ({ where }: { where: { id: string } }) => ({
      ...rows[where.id],
      childId: "child-1",
      child: { familyId: "fam-1" },
    }));
    prismaMock.device.updateMany.mockImplementation(async ({ where, data }: {
      where: { pushToken: string; id?: { not?: string } };
      data: { pushToken: string | null };
    }) => {
      let count = 0;
      for (const row of Object.values(rows)) {
        if (row.pushToken !== where.pushToken) continue;
        if (where.id?.not !== undefined && row.id === where.id.not) continue;
        row.pushToken = data.pushToken;
        count += 1;
      }
      return { count };
    });
    prismaMock.device.update.mockImplementation(async ({ where, data }: { where: { id: string }; data: { pushToken: string } }) => {
      rows[where.id].pushToken = data.pushToken;
      return rows[where.id];
    });

    const first = await app.inject({
      method: "POST",
      url: "/v1/devices/dev-1/push-token",
      headers: deviceHeader(app),
      payload: { token: SELF_TOKEN },
    });
    expect(first.statusCode).toBe(204);
    expect(rows["dev-1"].pushToken).toBe(SELF_TOKEN);

    const second = await app.inject({
      method: "POST",
      url: "/v1/devices/dev-2/push-token",
      headers: deviceHeader(app, { deviceId: "dev-2", childId: "child-1", familyId: "fam-1" }),
      payload: { token: SELF_TOKEN },
    });
    expect(second.statusCode).toBe(204);
    expect(rows["dev-2"].pushToken).toBe(SELF_TOKEN);
    expect(rows["dev-1"].pushToken).toBeNull();
    // The clearing write is issued before the adopting one — the order the transaction relies on.
    expect(prismaMock.device.updateMany.mock.invocationCallOrder[0]).toBeLessThan(
      prismaMock.device.update.mock.invocationCallOrder[0],
    );
    await app.close();
  });

  // MUTANT: loosen `PushTokenSchema` back to `{ pushToken }` / `min(1)` — the legacy body below then
  // answers 204 instead of 400 (`expected 204 to be 400`), and the `{ token }` cases 400 instead.
  // Measured: 3 failed | 26 passed, then reverted.
  it("rejects a 19-character token (400) and the old { pushToken } body (400), writing nothing", async () => {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    prismaMock.device.findUnique.mockResolvedValue(DEVICE);

    const short = await app.inject({
      method: "POST",
      url: "/v1/devices/dev-1/push-token",
      headers: deviceHeader(app),
      payload: { token: "x".repeat(19) },
    });
    expect(short.statusCode).toBe(400);

    // #319 review: the upper bound had no test, so `drop .max(4096)` survived. A 4097-character token
    // must be refused and a 4096-character one must be accepted — otherwise the bound can be off by one
    // in either direction without a red test.
    const tooLong = await app.inject({
      method: "POST",
      url: "/v1/devices/dev-1/push-token",
      headers: deviceHeader(app),
      payload: { token: "x".repeat(4097) },
    });
    expect(tooLong.statusCode).toBe(400);

    // Superseded: the body used to be `{ pushToken: z.string().min(1) }`. #319 moved it to
    // `{ token }`, 20..4096, matching `POST /v1/me/push-token`; the old field must not be accepted
    // silently, or an un-updated client would look like it had registered.
    const legacy = await app.inject({
      method: "POST",
      url: "/v1/devices/dev-1/push-token",
      headers: deviceHeader(app),
      payload: { pushToken: SELF_TOKEN },
    });
    expect(legacy.statusCode).toBe(400);

    expect(prismaMock.device.update).not.toHaveBeenCalled();
    expect(prismaMock.device.updateMany).not.toHaveBeenCalled();
    await app.close();
  });

  // MUTANT: drop `.max(4096)` from `PushTokenSchema` and this is the case that goes red
  // (`expected 204 to be 400`, 1 failed | 30 passed). Measured, then reverted.
  it("accepts a 4096-character token at the boundary (204) and stores it", async () => {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    prismaMock.device.findUnique.mockResolvedValue(DEVICE);

    const atLimit = "x".repeat(4096);
    const res = await app.inject({
      method: "POST",
      url: "/v1/devices/dev-1/push-token",
      headers: deviceHeader(app),
      payload: { token: atLimit },
    });
    expect(res.statusCode).toBe(204);
    expect(prismaMock.device.update).toHaveBeenCalledWith({ where: { id: "dev-1" }, data: { pushToken: atLimit } });
    await app.close();
  });

  // Audit finding 6's sanitization assertion ("no internalSecret, no pushToken") and the
  // permission test that followed it are gone with the parent route: a `204` with no body has no
  // device object to sanitize, and no parent reaches the write to need a permission gate. Both are
  // replaced by "refuses a parent session in the same family" above (#319, Claude, 2026-10-23).

  // The three `/push-token/self` tests that lived here are retired with the route (#319, Claude,
  // 2026-10-23): the path stays `POST /:id/push-token`, and its success case is
  // "a device JWT stores its own push token and answers 204 with no body" above. The sibling-403 and
  // parent-403 cases they covered are the first two tests of that block, against the real path.

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
      expect.objectContaining({
        where: { id: "dev-1" },
        data: expect.objectContaining({ locationGrant: "while_in_use", locationGrantReportedAt: expect.any(Date) }),
      }),
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
    // ...and it must not refresh the report's date either, or a stale grant would look fresh.
    expect(data).not.toHaveProperty("locationGrantReportedAt");
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

  it("activity: the device's own event time is kept, and a clock set forward is clamped (#260)", async () => {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    prismaMock.device.findUnique.mockResolvedValue(DEVICE);
    prismaMock.activityEvent.createMany.mockResolvedValue({ count: 5 });

    // Relative to now, deliberately: a hard-coded date would start clamping on its own anniversary.
    const now = Date.now();
    const iso = (ms: number) => new Date(ms).toISOString();
    const first = now - 8 * 60_000;      // a call from earlier this hour
    const second = now - 7 * 60_000;     // eight seconds after the first
    const third = second + 8_000;
    const future = now + 365 * 24 * 60 * 60_000;   // clock set a year forward
    const ancient = now - 180 * 24 * 60 * 60_000;  // clock set six months back
    const payload = {
      events: [
        { ts: iso(first), type: "call", payload: { number: "+10000000250", durationSec: 290, direction: "incoming" } },
        { ts: iso(second), type: "call", payload: { number: "+10000000251", durationSec: 50, direction: "incoming" } },
        { ts: iso(third), type: "sms", payload: { number: "+10000000252", bodyPreview: "hi" } },
        { ts: iso(future), type: "call", payload: { number: "+10000000253", durationSec: 12, direction: "outgoing" } },
        { ts: iso(ancient), type: "call", payload: { number: "+10000000254", durationSec: 5, direction: "missed" } },
      ],
    };

    const before = Date.now();
    const res = await app.inject({
      method: "POST",
      url: "/v1/devices/dev-1/activity",
      headers: deviceHeader(app),
      payload,
    });
    expect(res.statusCode).toBe(202);

    const rows = prismaMock.activityEvent.createMany.mock.calls[0][0].data as Array<{ ts: Date }>;
    expect(rows).toHaveLength(5);
    // Reported times are preserved to the millisecond, including the gap between two calls — the
    // assertion that was impossible while the server fell back to `new Date()`.
    expect(rows[0].ts.toISOString()).toBe(iso(first));
    expect(rows[1].ts.toISOString()).toBe(iso(second));
    expect(rows[2].ts.toISOString()).toBe(iso(third));
    expect(rows[1].ts.getTime() - rows[0].ts.getTime()).toBe(60_000);
    expect(rows[2].ts.getTime() - rows[1].ts.getTime()).toBe(8_000);
    // A future timestamp is bounded to now + 5 minutes rather than pinning itself to the top of the
    // parent's list forever.
    expect(rows[3].ts.getTime()).toBeGreaterThanOrEqual(before + 5 * 60_000 - 1_000);
    expect(rows[3].ts.getTime()).toBeLessThanOrEqual(Date.now() + 5 * 60_000 + 1_000);
    // A six-month-old timestamp is a deletion request against the 90-day retention sweep, so it is
    // floored to seven days: misdated, but kept and visible to the parent.
    const sevenDays = 7 * 24 * 60 * 60_000;
    expect(rows[4].ts.getTime()).toBeGreaterThanOrEqual(before - sevenDays - 1_000);
    expect(rows[4].ts.getTime()).toBeLessThanOrEqual(Date.now() - sevenDays + 1_000);

    // An event with no `ts` still gets the server's now: old agents stay compatible.
    prismaMock.activityEvent.createMany.mockClear();
    const legacy = await app.inject({
      method: "POST",
      url: "/v1/devices/dev-1/activity",
      headers: deviceHeader(app),
      payload: { events: [{ type: "call", payload: { number: "+10000000255", durationSec: 5, direction: "missed" } }] },
    });
    expect(legacy.statusCode).toBe(202);
    const legacyRows = prismaMock.activityEvent.createMany.mock.calls[0][0].data as Array<{ ts: Date }>;
    expect(Math.abs(legacyRows[0].ts.getTime() - Date.now())).toBeLessThan(5_000);
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


describe("#305 review: the witness code is a device credential, not a parent one", () => {
  beforeEach(() => {
    resetPrismaMock();
  });

  it("the command history never returns a show_reset_code payload", async () => {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    prismaMock.device.findUnique.mockResolvedValue(DEVICE);
    const now = new Date();
    const later = new Date(Date.now() + 10 * 60_000);
    // Claude's finding: the history returned the plaintext code, so a guardian — or the parent being
    // reset — could read the witness out of the parent app and the step proved nothing. He passed the
    // witness live with a code read this way.
    prismaMock.deviceCommand.findMany.mockResolvedValue([
      {
        id: "cmd-reset",
        deviceId: "dev-1",
        type: "show_reset_code",
        payload: { requestId: "req-1", parentName: "Alex's parent", code: "12345678", expiresAt: later.toISOString() },
        status: "pending",
        requestedBy: "system",
        createdAt: now,
        expiresAt: later,
        deliveredAt: null,
        ackedAt: null,
        result: null,
        attempts: 0,
      },
      {
        id: "cmd-ring",
        deviceId: "dev-1",
        type: "ring",
        payload: { source: "parent" },
        status: "acked",
        requestedBy: "parent-2",
        createdAt: now,
        expiresAt: later,
        deliveredAt: now,
        ackedAt: now,
        result: { ok: true },
        attempts: 1,
      },
    ]);

    const res = await app.inject({ method: "GET", url: "/v1/devices/dev-1/commands/history", headers: authHeader(app) });

    expect(res.statusCode).toBe(200);
    const items = res.json().items as Array<{ type: string; payload: unknown; status: string }>;
    const reset = items.find((i) => i.type === "show_reset_code")!;
    // The row still proves the command was queued, and what happened to it — only the payload goes.
    expect(reset.status).toBe("pending");
    expect(reset.payload).toEqual({});
    expect(res.body).not.toContain("12345678");
    // Other commands are untouched: the redaction is by type, not a blanket removal.
    expect(items.find((i) => i.type === "ring")!.payload).toEqual({ source: "parent" });
    await app.close();
  });

  it("a parent cannot send show_reset_code: only the reset flow produces it", async () => {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    prismaMock.device.findUnique.mockResolvedValue(DEVICE);

    // A parent-issueable command of this name would let any family parent — a guardian, or the parent
    // being reset — put a reset notice with a code of their choosing on the child's phone.
    const res = await app.inject({
      method: "POST",
      url: "/v1/devices/dev-1/command",
      headers: authHeader(app),
      payload: { command: "show_reset_code", payload: { code: "12345678" } },
    });

    expect(res.statusCode).toBe(400);
    expect(prismaMock.deviceCommand.create).not.toHaveBeenCalled();
    await app.close();
  });
});
