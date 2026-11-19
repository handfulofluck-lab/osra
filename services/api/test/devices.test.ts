import { beforeEach, describe, expect, it, vi } from "vitest";
import { deviceRoutes } from "../src/routes/devices.js";
import { familyAppliedVersion, rulesAppliedReached } from "../src/lib/rulesApplied.js";
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
    // #790: a parent's own enrollment is not a pending claim — nothing claimed anything, so the row is
    // paired on creation. Without `pairedAt` the device would be hidden from the parent that created it
    // and swept 30 minutes later.
    expect(prismaMock.device.create).toHaveBeenCalledWith({
      data: { childId: "child-1", platform: "android", model: "Pixel 7a", osVersion: "14", pushToken: "tok", pairedAt: expect.any(Date) },
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
    // #790 narrowed this query: the list is the family's phones, and a pending device (a pairing claim
    // whose phone has not made one accepted request) is not one of them yet. The assertion is exact, so
    // dropping the `pairedAt` filter fails here rather than silently drawing an unproven row.
    expect(prismaMock.device.findMany).toHaveBeenCalledWith(
      expect.objectContaining({ where: { child: { familyId: "fam-1" }, pairedAt: { not: null } } }),
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

  it("#830 B3: telemetry caps the app count and each app's minutes", async () => {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    prismaMock.device.findUnique.mockResolvedValue(DEVICE);

    const tooManyApps = { appUsage: Array.from({ length: 301 }, (_, i) => ({ packageId: `com.example.app${i}`, minutes: 1 })) };
    const tooManyMinutes = { appUsage: [{ packageId: "com.example.app", minutes: 1441 }] };
    const legacyTooMany = { perAppMinutes: Object.fromEntries(Array.from({ length: 301 }, (_, i) => [`com.example.app${i}`, 1])) };
    const legacyTooManyMinutes = { perAppMinutes: { "com.example.app": 1441 } };
    for (const payload of [tooManyApps, tooManyMinutes, legacyTooMany, legacyTooManyMinutes]) {
      const res = await app.inject({
        method: "POST",
        url: "/v1/devices/dev-1/telemetry",
        headers: deviceHeader(app),
        payload: payload as Record<string, unknown>,
      });
      expect(res.statusCode).toBe(400);
    }
    await app.close();
  });

  it("#830: telemetry per-app minutes become per-app rows, and the legacy map still maps", async () => {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    prismaMock.device.findUnique.mockResolvedValue(DEVICE);
    prismaMock.device.update.mockResolvedValue(DEVICE);
    prismaMock.appUsageDaily.upsert.mockResolvedValue({});

    const res = await app.inject({
      method: "POST",
      url: "/v1/devices/dev-1/telemetry",
      headers: deviceHeader(app),
      payload: {
        totalMinutes: 22,
        appUsage: [
          { packageId: "com.google.android.youtube", minutes: 15 },
          { packageId: "com.android.chrome", minutes: 7 },
        ],
      },
    });
    expect(res.statusCode).toBe(202);
    const created = prismaMock.appUsageDaily.upsert.mock.calls.map(
      ([args]: [{ create: { childId: string; deviceId: string; app: string; minutes: number } }]) => args.create,
    );
    expect(created).toEqual(
      expect.arrayContaining([
        expect.objectContaining({ childId: "child-1", deviceId: "dev-1", app: "com.google.android.youtube", minutes: 15 }),
        expect.objectContaining({ childId: "child-1", deviceId: "dev-1", app: "com.android.chrome", minutes: 7 }),
      ]),
    );

    // Both shapes in one report: `appUsage` is the contract, so the legacy map is not folded in.
    prismaMock.appUsageDaily.upsert.mockClear();
    const both = await app.inject({
      method: "POST",
      url: "/v1/devices/dev-1/telemetry",
      headers: deviceHeader(app),
      payload: {
        appUsage: [{ packageId: "com.google.android.youtube", minutes: 9 }],
        perAppMinutes: { "com.android.chrome": 40 },
      },
    });
    expect(both.statusCode).toBe(202);
    const bothRows = prismaMock.appUsageDaily.upsert.mock.calls.map(
      ([args]: [{ create: { app: string; minutes: number } }]) => args.create,
    );
    expect(bothRows).toEqual([expect.objectContaining({ app: "com.google.android.youtube", minutes: 9 })]);
    expect(bothRows.some((row) => row.app === "com.android.chrome")).toBe(false);

    // The shape Android sent before the contract was standardised, accepted for one release.
    prismaMock.appUsageDaily.upsert.mockClear();
    const legacy = await app.inject({
      method: "POST",
      url: "/v1/devices/dev-1/telemetry",
      headers: deviceHeader(app),
      payload: { perAppMinutes: { "com.google.android.youtube": 5 } },
    });
    expect(legacy.statusCode).toBe(202);
    expect(prismaMock.appUsageDaily.upsert).toHaveBeenCalledWith(
      expect.objectContaining({ create: expect.objectContaining({ app: "com.google.android.youtube", minutes: 5 }) }),
    );
    await app.close();
  });

  it("#830: a device with no child writes no per-app row", async () => {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    prismaMock.device.findUnique.mockResolvedValue({ ...DEVICE, childId: null });
    prismaMock.device.update.mockResolvedValue(DEVICE);

    const res = await app.inject({
      method: "POST",
      url: "/v1/devices/dev-1/telemetry",
      headers: deviceHeader(app),
      payload: { appUsage: [{ packageId: "com.google.android.youtube", minutes: 5 }] },
    });
    expect(res.statusCode).toBe(202);
    expect(prismaMock.appUsageDaily.upsert).not.toHaveBeenCalled();
    await app.close();
  });

  /**
   * Issue #475: the applied rules version is a *report*, and only a version the server has issued counts.
   * A number from the future would clear the parent's "the phone hasn't picked this up yet" line on a
   * caller bug, which is worse than the warning itself.
   */
  it("issue #475: stores an applied rules version the server issued, and ignores a future one", async () => {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    prismaMock.device.findUnique.mockResolvedValue(DEVICE);
    prismaMock.device.update.mockResolvedValue(DEVICE);

    // Issued version is 5.
    prismaMock.ruleSet.findUnique.mockResolvedValue({ rulesVersion: 5 });

    const accepted = await app.inject({
      method: "POST",
      url: "/v1/devices/dev-1/telemetry",
      headers: deviceHeader(app),
      payload: { appliedRulesVersion: 5 },
    });
    expect(accepted.statusCode).toBe(202);
    // The route also stamps lastSeen/status on every telemetry, so assert on the field, not the call.
    expect(
      prismaMock.device.update.mock.calls.some(
        ([args]: [{ data?: Record<string, unknown> }]) => args.data?.appliedRulesVersion === 5,
      ),
    ).toBe(true);

    prismaMock.device.update.mockClear();
    const future = await app.inject({
      method: "POST",
      url: "/v1/devices/dev-1/telemetry",
      headers: deviceHeader(app),
      payload: { appliedRulesVersion: 99 },
    });
    expect(future.statusCode).toBe(202);
    expect(
      prismaMock.device.update.mock.calls.some(
        ([args]: [{ data?: Record<string, unknown> }]) => "appliedRulesVersion" in (args.data ?? {}),
      ),
    ).toBe(false);
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
  it("telemetry: a device token may post only for its own id (403 to a sibling); a parent token is refused (403 device_role_required)", async () => {
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

    // Plan 2.7 F2 (Claude, #329, 2026-10-23): this used to pin a parent's 202 ("parents stay
    // family-scoped"). Data the phone reports must come from the phone, so every parent token is now
    // refused and nothing is written.
    const writesBefore = prismaMock.device.update.mock.calls.length;
    for (const url of ["/v1/devices/dev-1/telemetry", "/v1/devices/dev-2/telemetry"]) {
      const parent = await app.inject({ method: "POST", url, headers: authHeader(app), payload: { batteryPct: 10 } });
      expect(parent.statusCode).toBe(403);
      expect(parent.json().error).toBe("device_role_required");
    }
    expect(prismaMock.device.update.mock.calls.length).toBe(writesBefore);

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

  it("activity: a device token may post only for its own id (403 to a sibling); a parent token is refused (403 device_role_required)", async () => {
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

    // Plan 2.7 F2 (Claude, #329, 2026-10-23): this used to pin a parent's 202. A parent token could
    // forge the calls, texts and usage minutes in the child's activity log, so it is now refused.
    const rowsBefore = prismaMock.activityEvent.createMany.mock.calls.length;
    for (const url of ["/v1/devices/dev-1/activity", "/v1/devices/dev-2/activity"]) {
      const parent = await app.inject({ method: "POST", url, headers: authHeader(app), payload: batch });
      expect(parent.statusCode).toBe(403);
      expect(parent.json().error).toBe("device_role_required");
    }
    expect(prismaMock.activityEvent.createMany.mock.calls.length).toBe(rowsBefore);

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

  it("issue #830/S1: the per-app split in telemetry reaches AppUsageDaily", async () => {
    // The parent's usage report read `apps: []` for every family because the only per-app writer was fed by
    // persistent activity events, and the agent marks all of its own `app_usage` events `live` (filtered by
    // BUG-002). The same telemetry that carries the total already carries the split; this row pins that it
    // is stored, and that the total keeps its single writer.
    const app = await buildApp(deviceRoutes, "/v1/devices");
    prismaMock.device.findUnique.mockResolvedValue({ ...DEVICE, childId: "child-1" });
    prismaMock.device.update.mockResolvedValue(DEVICE);

    const res = await app.inject({
      method: "POST",
      url: "/v1/devices/dev-1/telemetry",
      headers: deviceHeader(app),
      payload: {
        totalMinutes: 22,
        appUsage: [
          { packageId: "com.google.android.youtube", minutes: 14.6 },
          { packageId: "com.whatsapp", minutes: 7 },
          // A phone that reports the reserved total key inside the split must not be able to write the
          // total a second time. Mutant: drop the `app === DEVICE_TOTAL_APP` guard and this row doubles it.
          { packageId: "*", minutes: 5 },
        ],
      },
    });

    expect(res.statusCode).toBe(202);
    const rows = prismaMock.appUsageDaily.upsert.mock.calls.map(([args]: [{ where: { childId_deviceId_day_app: { app: string } }; create: { minutes: number } }]) => [
      args.where.childId_deviceId_day_app.app,
      args.create.minutes,
    ]);
    expect(rows).toEqual(expect.arrayContaining([["com.google.android.youtube", 15], ["com.whatsapp", 7]]));
    // `*` is the total's own row, written once by `recordDeviceTotal`: a second writer would double it.
    const totals = prismaMock.appUsageDaily.upsert.mock.calls.filter(
      ([args]: [{ where: { childId_deviceId_day_app: { app: string } } }]) => args.where.childId_deviceId_day_app.app === "*",
    );
    expect(totals).toHaveLength(1);
    expect((totals[0][0] as { create: { minutes: number } }).create.minutes).toBe(22);
    await app.close();
  });

  it("issue #830/S1: an empty or zero-minute entry is skipped, and repeats accumulate", async () => {
    // The schema already refuses a blank packageId with a 400 for the whole tick (so the writer cannot see
    // one), but a zero-minute row is legal and must not create a row, and two entries for one package in
    // one tick are the same counter, not a race to overwrite.
    const app = await buildApp(deviceRoutes, "/v1/devices");
    prismaMock.device.findUnique.mockResolvedValue({ ...DEVICE, childId: "child-1" });
    prismaMock.device.update.mockResolvedValue(DEVICE);

    const res = await app.inject({
      method: "POST",
      url: "/v1/devices/dev-1/telemetry",
      headers: deviceHeader(app),
      payload: {
        batteryPct: 40,
        appUsage: [
          { packageId: "com.whatsapp", minutes: 0 },
          { packageId: "com.whatsapp", minutes: 3 },
        ],
      },
    });

    expect(res.statusCode).toBe(202);
    const perApp = prismaMock.appUsageDaily.upsert.mock.calls.filter(
      ([args]: [{ where: { childId_deviceId_day_app: { app: string } } }]) => args.where.childId_deviceId_day_app.app === "com.whatsapp",
    );
    expect(perApp).toHaveLength(1);
    expect((perApp[0][0] as { create: { minutes: number } }).create.minutes).toBe(3);
    await app.close();
  });

  it("issue #830/S1 C1: the field Android actually sends reaches AppUsageDaily", async () => {
    // The exact `TelemetryDto` wire shape (`PayloadDtos.kt:19-23`): `perAppMinutes` as a map, no `appUsage`.
    // Antigravity's C1: without this branch the rollup is a no-op on every real phone, tests green or not.
    const app = await buildApp(deviceRoutes, "/v1/devices");
    prismaMock.device.findUnique.mockResolvedValue({ ...DEVICE, childId: "child-1" });
    prismaMock.device.update.mockResolvedValue(DEVICE);

    const res = await app.inject({
      method: "POST",
      url: "/v1/devices/dev-1/telemetry",
      headers: deviceHeader(app),
      payload: {
        perAppMinutes: { "com.google.android.youtube": 15, "com.whatsapp": 7, "*": 5 },
        totalMinutes: 22,
        unlockCount: 3,
        batteryPct: 80,
        locationGrant: "background",
      },
    });

    expect(res.statusCode).toBe(202);
    const rows = prismaMock.appUsageDaily.upsert.mock.calls.map(
      ([a]: [{ where: { childId_deviceId_day_app: { app: string } }; create: { minutes: number } }]) => [
        a.where.childId_deviceId_day_app.app,
        a.create.minutes,
      ],
    );
    expect(rows).toEqual(expect.arrayContaining([["com.google.android.youtube", 15], ["com.whatsapp", 7]]));
    // The map's `*` entry must not write the total either — same guard as the array shape.
    const totals = rows.filter(([k]: [string, number]) => k === "*");
    expect(totals).toHaveLength(1);
    expect(totals[0][1]).toBe(22);
    await app.close();
  });

  it("issue #830/S1 C1: both shapes in one tick are written once, not added", async () => {
    // Precedence, not addition: a transitional client must not double its own minutes. Mutant: feed both
    // lists into recordAppUsage and the count doubles.
    const app = await buildApp(deviceRoutes, "/v1/devices");
    prismaMock.device.findUnique.mockResolvedValue({ ...DEVICE, childId: "child-1" });
    prismaMock.device.update.mockResolvedValue(DEVICE);

    await app.inject({
      method: "POST",
      url: "/v1/devices/dev-1/telemetry",
      headers: deviceHeader(app),
      payload: {
        appUsage: [{ packageId: "com.whatsapp", minutes: 5 }],
        perAppMinutes: { "com.whatsapp": 9 },
      },
    });

    const whatsapp = prismaMock.appUsageDaily.upsert.mock.calls.filter(
      ([a]: [{ where: { childId_deviceId_day_app: { app: string } } }]) => a.where.childId_deviceId_day_app.app === "com.whatsapp",
    );
    expect(whatsapp).toHaveLength(1);
    expect((whatsapp[0][0] as { create: { minutes: number } }).create.minutes).toBe(5);
    await app.close();
  });

  it("issue #830/S1: a failed per-app rollup does not change the response or lose the tick", async () => {
    // Hydrogen's B1 (#901): §5 promises that a broken rollup cannot fail the upload. Mutant: `throw err` in
    // the handler's catch, and this row is the only thing that notices.
    const app = await buildApp(deviceRoutes, "/v1/devices");
    prismaMock.device.findUnique.mockResolvedValue({ ...DEVICE, childId: "child-1" });
    prismaMock.device.update.mockResolvedValue(DEVICE);
    prismaMock.appUsageDaily.upsert.mockRejectedValueOnce(new Error("db down"));

    const res = await app.inject({
      method: "POST",
      url: "/v1/devices/dev-1/telemetry",
      headers: deviceHeader(app),
      // No `totalMinutes`: the only rollup that can fail here is the per-app one.
      payload: { batteryPct: 55, appUsage: [{ packageId: "com.whatsapp", minutes: 4 }] },
    });

    expect(res.statusCode).toBe(202);
    // The heartbeat still happened: the device row was refreshed, so lastSeen advances as usual.
    expect(prismaMock.device.update).toHaveBeenCalled();
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

/**
 * #865: the rules banner and the delivery status told a parent opposite things. The banner reads the
 * child's reduced `appliedRulesVersion`; nothing pushed it, so it cleared only when an unrelated socket
 * frame arrived. The telemetry route now publishes `rules_applied` on the family channel the moment the
 * last reporting device catches up — with the same reduced number the banner reads, and nothing else.
 */
describe("applied rules version push (#865)", () => {
  const redis = () => getRedis() as unknown as import("./helpers.js").MockRedis;

  beforeEach(() => {
    resetPrismaMock();
  });

  const report = (app: Awaited<ReturnType<typeof buildApp>>, appliedRulesVersion: number) =>
    app.inject({
      method: "POST",
      url: "/v1/devices/dev-1/telemetry",
      headers: deviceHeader(app),
      payload: { appliedRulesVersion },
    });

  it("publishes rules_applied on the family channel when the last device catches up", async () => {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    prismaMock.device.findUnique.mockResolvedValue(DEVICE);
    prismaMock.device.update.mockResolvedValue(DEVICE);
    prismaMock.ruleSet.findUnique.mockResolvedValue({ rulesVersion: 4 });
    prismaMock.device.findMany.mockResolvedValue([{ appliedRulesVersion: 4 }]);
    redis().publish.mockClear();

    const res = await report(app, 4);
    expect(res.statusCode).toBe(202);
    expect(redis().publish).toHaveBeenCalledWith("family:fam-1:events", expect.stringContaining('"rules_applied"'));

    const frame = JSON.parse(redis().publish.mock.calls.at(-1)![1] as string);
    // Exactly the number, scoped to the child: no rule content and no device detail ride on it.
    expect(frame).toEqual({ type: "rules_applied", payload: { childId: "child-1", appliedRulesVersion: 4 } });
    expect(JSON.stringify(frame)).not.toContain("dev-1");
    await app.close();
  });

  it("publishes once, not on every upload that repeats the version", async () => {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    prismaMock.ruleSet.findUnique.mockResolvedValue({ rulesVersion: 4 });
    prismaMock.device.findMany.mockResolvedValue([{ appliedRulesVersion: 4 }]);
    prismaMock.device.update.mockResolvedValue(DEVICE);
    // The row as `requireFamily` loads it: first upload sees a device that never reported, second sees the
    // version the first one stored. That is the transition, and it happens once.
    prismaMock.device.findUnique
      .mockResolvedValueOnce(DEVICE)
      .mockResolvedValue({ ...DEVICE, appliedRulesVersion: 4 });
    redis().publish.mockClear();

    expect((await report(app, 4)).statusCode).toBe(202);
    const afterFirst = redis().publish.mock.calls.filter(([, message]) => String(message).includes('"rules_applied"')).length;
    expect(afterFirst).toBe(1);

    expect((await report(app, 4)).statusCode).toBe(202);
    const afterSecond = redis().publish.mock.calls.filter(([, message]) => String(message).includes('"rules_applied"')).length;
    // The mutant: drop `advanced` and every telemetry tick republishes, making every open parent app
    // refetch the family snapshot for as long as nothing changes.
    expect(afterSecond).toBe(1);
    await app.close();
  });

  it("publishes again when the version moves up and the family is caught up", async () => {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    prismaMock.ruleSet.findUnique.mockResolvedValue({ rulesVersion: 5 });
    prismaMock.device.findMany.mockResolvedValue([{ appliedRulesVersion: 5 }]);
    prismaMock.device.update.mockResolvedValue(DEVICE);
    prismaMock.device.findUnique.mockResolvedValue({ ...DEVICE, appliedRulesVersion: 4 });
    redis().publish.mockClear();

    expect((await report(app, 5)).statusCode).toBe(202);
    const frames = redis().publish.mock.calls.filter(([, message]) => String(message).includes('"rules_applied"'));
    // The mutant: treat a repeat of the *old* number as caught up, or compare against the new version and
    // this row stays quiet while the phone has actually moved.
    expect(frames).toHaveLength(1);
    expect(JSON.parse(frames[0][1] as string).payload.appliedRulesVersion).toBe(5);
    await app.close();
  });

  it("stays quiet while another device of the same child is still behind", async () => {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    prismaMock.device.findUnique.mockResolvedValue(DEVICE);
    prismaMock.device.update.mockResolvedValue(DEVICE);
    prismaMock.ruleSet.findUnique.mockResolvedValue({ rulesVersion: 4 });
    // The second device is on version 2: the family has not caught up, so no frame.
    prismaMock.device.findMany.mockResolvedValue([{ appliedRulesVersion: 4 }, { appliedRulesVersion: 2 }]);
    redis().publish.mockClear();

    const res = await report(app, 4);
    expect(res.statusCode).toBe(202);
    expect(redis().publish).not.toHaveBeenCalledWith("family:fam-1:events", expect.stringContaining('"rules_applied"'));
    await app.close();
  });

  it("stays quiet when no ruleset has ever been issued for the child", async () => {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    prismaMock.device.findUnique.mockResolvedValue(DEVICE);
    prismaMock.device.update.mockResolvedValue(DEVICE);
    prismaMock.ruleSet.findUnique.mockResolvedValue(null);
    prismaMock.device.findMany.mockResolvedValue([{ appliedRulesVersion: 1 }]);
    redis().publish.mockClear();

    const res = await report(app, 1);
    expect(res.statusCode).toBe(202);
    expect(redis().publish).not.toHaveBeenCalledWith("family:fam-1:events", expect.stringContaining('"rules_applied"'));
    await app.close();
  });

  it("stays quiet for a version above the issued one and when the report is omitted", async () => {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    prismaMock.device.findUnique.mockResolvedValue(DEVICE);
    prismaMock.device.update.mockResolvedValue(DEVICE);
    prismaMock.ruleSet.findUnique.mockResolvedValue({ rulesVersion: 4 });
    prismaMock.device.findMany.mockResolvedValue([{ appliedRulesVersion: 4 }]);
    redis().publish.mockClear();

    expect((await report(app, 99)).statusCode).toBe(202);
    const plain = await app.inject({
      method: "POST",
      url: "/v1/devices/dev-1/telemetry",
      headers: deviceHeader(app),
      payload: { batteryPct: 44 },
    });
    expect(plain.statusCode).toBe(202);
    expect(redis().publish).not.toHaveBeenCalledWith("family:fam-1:events", expect.stringContaining('"rules_applied"'));
    // A future version is not stored either — the #475 rule the push must not weaken.
    expect(
      prismaMock.device.update.mock.calls.some(
        ([args]: [{ data?: Record<string, unknown> }]) => args.data?.appliedRulesVersion === 99,
      ),
    ).toBe(false);
    await app.close();
  });

  it("publishes exactly one frame, on the channel of the family that owns the device", async () => {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    prismaMock.device.findUnique.mockResolvedValue(DEVICE);
    prismaMock.device.update.mockResolvedValue(DEVICE);
    prismaMock.ruleSet.findUnique.mockResolvedValue({ rulesVersion: 2 });
    prismaMock.device.findMany.mockResolvedValue([{ appliedRulesVersion: 2 }]);
    redis().publish.mockClear();

    const res = await report(app, 2);
    expect(res.statusCode).toBe(202);

    // The family comes from the device row, never from the request: a device cannot steer the frame at
    // another family, and `requireFamily` answers 403 long before this route if its row belongs to one.
    const frames = redis().publish.mock.calls.filter(([, message]) => String(message).includes('"rules_applied"'));
    expect(frames).toHaveLength(1);
    expect(frames[0][0]).toBe("family:fam-1:events");
    await app.close();
  });
});

describe("rulesApplied reduction (#865)", () => {
  it("is the lowest version any device reported", () => {
    expect(familyAppliedVersion([3, 1, 2])).toBe(1);
  });

  it("ignores a device that has never reported instead of counting it as zero", () => {
    // The mutant: treat null as 0 and the banner never clears on a family with one fresh install.
    expect(familyAppliedVersion([3, null, undefined, 2])).toBe(2);
  });

  it("is null when nothing has reported", () => {
    expect(familyAppliedVersion([null, undefined])).toBeNull();
    expect(familyAppliedVersion([])).toBeNull();
  });

  it("has reached only when the issued version exists and the family meets it", () => {
    expect(rulesAppliedReached(4, 4)).toBe(true);
    expect(rulesAppliedReached(4, 5)).toBe(false);
    expect(rulesAppliedReached(null, 4)).toBe(false);
    // No ruleset ever issued: there is nothing to catch up to and nothing to announce.
    expect(rulesAppliedReached(5, 0)).toBe(false);
  });
});

/**
 * Issue #867: a child phone restart takes 1–2 minutes and the 30-minute silence window must not be lowered
 * (a false `device_silent` critical is worse than a late one), so the restart is reported by the device as
 * `bootedAt` + `bootCount` and this route turns it into one `device_restarted` alert.
 *
 * The rows here prove what the pure module cannot: which column the route writes and when, that a first
 * report is silent (#884 blocker 1), that a moved clock with an unchanged boot count is not a restart
 * (#884 blocker 2), that the alert uses the family's zone and the boot fields never reach the cached
 * telemetry blob. Each row names the mutant it kills where the mutant is not obvious from the assertion.
 */
describe("device restart reporting (#867)", () => {
  beforeEach(() => {
    resetPrismaMock();
  });

  /** A boot that many minutes ago, relative to the real clock. */
  const minutesAgo = (minutes: number) => new Date(Date.now() - minutes * 60_000);

  /**
   * The row as `requireFamily` loads it. `update` writes back onto it so the second request sees what the
   * first one stored, as two real ticks would; `mockResolvedValue` would answer with the pre-restart row
   * forever and make a repeated tick look like a second restart.
   */
  function storedDevice(overrides: Record<string, unknown> = {}) {
    const row: Record<string, unknown> = {
      id: "dev-1",
      childId: "child-1",
      model: "Pixel 7a",
      lastSeen: minutesAgo(7),
      lastBootAt: null,
      lastBootCount: null,
      child: { familyId: "fam-1", displayName: "Alex" },
      ...overrides,
    };
    prismaMock.device.findUnique.mockResolvedValue(row);
    prismaMock.device.update.mockImplementation(async ({ data }: { data: Record<string, unknown> }) => Object.assign(row, data));
    prismaMock.alert.create.mockImplementation(async ({ data }: { data: Record<string, unknown> }) => ({ id: "alert-1", ...data }));
    prismaMock.family.findUnique.mockResolvedValue({ timezone: "Asia/Dubai" });
    return row;
  }

  const tick = (app: Awaited<ReturnType<typeof buildApp>>, payload: Record<string, unknown>) =>
    app.inject({ method: "POST", url: "/v1/devices/dev-1/telemetry", headers: deviceHeader(app), payload });

  const bootWrites = () =>
    prismaMock.device.update.mock.calls.filter(
      ([args]: [{ data?: Record<string, unknown> }]) => "lastBootAt" in (args.data ?? {}) || "lastBootCount" in (args.data ?? {}),
    );

  it("stores a first report and raises nothing; a moved instant on the next tick alerts", async () => {
    // Blocker 1 of #884: nothing is stored, so the server cannot know a restart happened. The mutant —
    // alert on a first report — would tell every family on ship day about a boot days old.
    const app = await buildApp(deviceRoutes, "/v1/devices");
    storedDevice();

    expect((await tick(app, { batteryPct: 50, bootedAt: minutesAgo(5).toISOString() })).statusCode).toBe(202);
    expect(bootWrites()).toHaveLength(1);
    expect(prismaMock.alert.create).not.toHaveBeenCalled();

    // Same phone, no counter (an older agent): the fallback compares the instant, and two minutes is a
    // restart. This is the row the review asked for — store on the first tick, alert on the moved one.
    expect((await tick(app, { batteryPct: 49, bootedAt: minutesAgo(3).toISOString() })).statusCode).toBe(202);
    expect(prismaMock.alert.create).toHaveBeenCalledTimes(1);
    const alert = prismaMock.alert.create.mock.calls[0][0].data as Record<string, unknown>;
    expect(alert).toMatchObject({ severity: "info", category: "device_restarted", title: "Device restarted" });
    await app.close();
  });

  it("a moved clock with an unchanged boot count is not a restart and rewrites nothing", async () => {
    // Blocker 2 of #884: the instant is derived from a wall clock a child can set. The mutant — let the
    // instant decide while a count is present — alerts on every tick after one clock change.
    const app = await buildApp(deviceRoutes, "/v1/devices");
    const storedInstant = minutesAgo(180);
    const row = storedDevice({ lastBootAt: storedInstant, lastBootCount: 7, lastSeen: minutesAgo(182) });

    // An hour of clock drift, same count.
    expect((await tick(app, { bootedAt: minutesAgo(120).toISOString(), bootCount: 7 })).statusCode).toBe(202);
    expect(bootWrites()).toHaveLength(0);
    expect(prismaMock.alert.create).not.toHaveBeenCalled();
    expect(row.lastBootAt).toEqual(storedInstant);
    await app.close();
  });

  it("a higher boot count alerts even when the instant moved, and the gap comes from lastSeen", async () => {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    storedDevice({ lastBootAt: minutesAgo(180), lastBootCount: 7, lastSeen: minutesAgo(122) });

    expect((await tick(app, { bootedAt: minutesAgo(120).toISOString(), bootCount: 8 })).statusCode).toBe(202);
    expect(prismaMock.alert.create).toHaveBeenCalledTimes(1);
    const alert = prismaMock.alert.create.mock.calls[0][0].data as { severity: string; body: string; metadata: Record<string, unknown> };
    expect(alert.severity).toBe("info");
    expect(alert.body).toMatch(/^Pixel 7a restarted (?:yesterday )?at \d\d:\d\d and was back after 2 minutes\.$/);
    expect(alert.metadata).toMatchObject({
      type: "device_restarted",
      gapMinutes: 2,
      bodyKey: "alertBodyDeviceRestarted",
      bodyParams: { model: "Pixel 7a", gapMinutes: 2 },
    });
    // The count that decided the restart is stored, so the next tick's comparison has it.
    expect(bootWrites()[0][0].data).toMatchObject({ lastBootCount: 8 });
    await app.close();
  });

  it("adopts a counter on a same-boot tick from an upgraded agent, silently", async () => {
    // Fable's review of #884: a row with an instant and no counter is an agent upgraded in place. Recording
    // the counter on this tick — no alert, no instant rewrite — is what moves the next restart's decision off
    // the wall clock. The mutant, waiting for the next reboot, leaves the clock-move weakness for a full uptime.
    const app = await buildApp(deviceRoutes, "/v1/devices");
    const storedInstant = minutesAgo(90);
    storedDevice({ lastBootAt: storedInstant, lastBootCount: null });

    expect((await tick(app, { bootedAt: storedInstant.toISOString(), bootCount: 5 })).statusCode).toBe(202);
    expect(prismaMock.alert.create).not.toHaveBeenCalled();
    expect(bootWrites()).toHaveLength(1);
    expect(bootWrites()[0][0].data).toMatchObject({ lastBootCount: 5 });
    // The instant is not rewritten: this is not a new boot, and moving it would misdate the next gap.
    expect(bootWrites()[0][0].data).not.toHaveProperty("lastBootAt");
    await app.close();
  });

  it("alerts with a dedupe key that names the deciding count", async () => {
    // Fable's x10 on #884: the key gained the count, and the row that guarded it was lost. Two API instances
    // both deciding "new boot" for one restart would otherwise push twice; the count is part of the identity
    // because a moved clock can repeat an instant.
    const app = await buildApp(deviceRoutes, "/v1/devices");
    storedDevice({ lastBootAt: minutesAgo(180), lastBootCount: 7, lastSeen: minutesAgo(122) });
    const boot = minutesAgo(120);

    expect((await tick(app, { bootedAt: boot.toISOString(), bootCount: 8 })).statusCode).toBe(202);
    const alert = prismaMock.alert.create.mock.calls[0][0].data as { dedupeKey?: string };
    expect(alert.dedupeKey).toBe(`boot|${boot.toISOString()}|8`);
    await app.close();
  });

  it("a lower boot count is a new baseline, not a restart", async () => {
    // A wipe or a restore reports an earlier counter. The mutant — alert on any change — calls it tampering.
    const app = await buildApp(deviceRoutes, "/v1/devices");
    storedDevice({ lastBootAt: minutesAgo(180), lastBootCount: 9 });

    expect((await tick(app, { bootedAt: minutesAgo(5).toISOString(), bootCount: 2 })).statusCode).toBe(202);
    expect(prismaMock.alert.create).not.toHaveBeenCalled();
    expect(bootWrites()[0][0].data).toMatchObject({ lastBootCount: 2 });
    await app.close();
  });

  it("raises again for a different boot, as a warning once the gap reaches the silence window", async () => {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    const boot = minutesAgo(5);
    storedDevice({ lastBootAt: minutesAgo(24 * 60), lastSeen: new Date(boot.getTime() - 40 * 60_000) });

    expect((await tick(app, { bootedAt: boot.toISOString() })).statusCode).toBe(202);
    expect(prismaMock.alert.create).toHaveBeenCalledTimes(1);
    const alert = prismaMock.alert.create.mock.calls[0][0].data as { severity: string; body: string; metadata: { gapMinutes: number } };
    // 40 minutes: the parent would also have received `device_silent` at 30, so this explains an alarm
    // they already got instead of reading like a routine reboot.
    expect(alert.severity).toBe("warning");
    expect(alert.metadata.gapMinutes).toBe(40);
    expect(alert.body).toMatch(/^Pixel 7a restarted (?:yesterday )?at \d\d:\d\d and was back after 40 minutes\.$/);
    await app.close();
  });

  it("drops a boot instant from the future: no write, no alert, the upload still accepted", async () => {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    storedDevice({ lastBootAt: minutesAgo(180), lastBootCount: 7 });

    const future = new Date(Date.now() + 6 * 60_000).toISOString();
    // The count differs too: the whole report is a caller bug, so nothing is stored — the next tick with a
    // sane clock still sees the difference and reports it then.
    expect((await tick(app, { batteryPct: 30, bootedAt: future, bootCount: 8 })).statusCode).toBe(202);
    expect(bootWrites()).toHaveLength(0);
    expect(prismaMock.alert.create).not.toHaveBeenCalled();

    // An older agent sends no `bootedAt` at all: the column keeps what it had and nothing is raised.
    expect((await tick(app, { batteryPct: 29 })).statusCode).toBe(202);
    expect(bootWrites()).toHaveLength(0);
    expect(prismaMock.alert.create).not.toHaveBeenCalled();
    await app.close();
  });

  it("keeps the boot fields out of the cached telemetry blob (x11)", async () => {
    // Fable's x11: a copy in `device:<id>:telemetry` would be a second source of truth, and a dropped
    // clock-ahead value would reappear through the blob the parent reads.
    const app = await buildApp(deviceRoutes, "/v1/devices");
    storedDevice();
    const redis = getRedis() as unknown as import("./helpers.js").MockRedis;

    expect((await tick(app, { bootedAt: minutesAgo(5).toISOString(), bootCount: 7 })).statusCode).toBe(202);
    // The last write, not the first: other rows in this file also store this key, and reading theirs would
    // prove nothing about this route.
    const write = redis.set.mock.calls.filter(([key]) => key === "device:dev-1:telemetry").at(-1);
    expect(write).toBeDefined();
    const blob = JSON.parse(write![1] as string);
    expect(blob).not.toHaveProperty("bootedAt");
    expect(blob).not.toHaveProperty("bootCount");
    expect(blob).toHaveProperty("receivedAt");
    await app.close();
  });

  it("renders the alert in the family's timezone, not UTC (x12)", async () => {
    // Fable's x12: the pure function is tested with a zone; the mutant is the route passing "UTC" — or
    // reading the wrong family — and a wrong hour in "restarted at …" is the made-up number the body warns
    // about. The fixture family is Asia/Dubai, so the two clocks differ by four hours.
    const app = await buildApp(deviceRoutes, "/v1/devices");
    const boot = minutesAgo(10);
    storedDevice({ lastBootAt: minutesAgo(180), lastSeen: new Date(boot.getTime() - 2 * 60_000) });

    expect((await tick(app, { bootedAt: boot.toISOString() })).statusCode).toBe(202);
    const alert = prismaMock.alert.create.mock.calls[0][0].data as { body: string };
    const hhmm = (timeZone: string) =>
      new Intl.DateTimeFormat("en-GB", { timeZone, hour: "2-digit", minute: "2-digit", hourCycle: "h23" }).format(boot);
    expect(hhmm("Asia/Dubai")).not.toBe(hhmm("UTC"));
    expect(alert.body).toMatch(new RegExp(`^Pixel 7a restarted (?:yesterday )?at ${hhmm("Asia/Dubai")} and was back`));
    expect(alert.body).not.toContain(`at ${hhmm("UTC")} `);
    await app.close();
  });

  it("exposes the stored boot state on the parent's device read", async () => {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    const boot = new Date("2026-11-17T10:00:00Z");
    prismaMock.device.findUnique.mockResolvedValue({ ...DEVICE, model: "Pixel 7a", lastBootAt: boot, lastBootCount: 7 });

    const res = await app.inject({ method: "GET", url: "/v1/devices/dev-1", headers: authHeader(app) });
    expect(res.statusCode).toBe(200);
    expect(res.json().device.lastBootAt).toBe("2026-11-17T10:00:00.000Z");
    expect(res.json().device.lastBootCount).toBe(7);
    await app.close();
  });
});
