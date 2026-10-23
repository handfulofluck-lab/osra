import { beforeEach, describe, expect, it, vi } from "vitest";
import { locationRoutes } from "../src/routes/location.js";
import { authHeader, buildApp, deviceHeader, prismaMock, resetPrismaMock } from "./helpers.js";

vi.mock("../src/db.js", async () => {
  const { prismaMock } = await import("./helpers.js");
  return { prisma: prismaMock };
});
vi.mock("ioredis", async () => {
  const { MockRedis } = await import("./helpers.js");
  return { Redis: MockRedis };
});

const CHILD_ID = "child-1";
const SIBLING_ID = "child-2";
const DEVICE_ID = "device-1";
const PING = { childId: CHILD_ID, deviceId: DEVICE_ID, lat: 40.7128, lng: -74.006, accuracyM: 5 };

describe("POST /v1/location/ping — caller eligibility", () => {
  beforeEach(() => {
    resetPrismaMock();
    prismaMock.child.findUnique.mockResolvedValue({ id: CHILD_ID, familyId: "fam-1" });
    prismaMock.device.findUnique.mockResolvedValue({ id: DEVICE_ID, childId: CHILD_ID });
    prismaMock.device.update.mockResolvedValue({});
    prismaMock.geofence.findMany.mockResolvedValue([]);
    prismaMock.locationPing.create.mockResolvedValue({ id: "ping-1" });
  });

  it("rejects a password-reset purpose token (401) even though it is a valid JWT", async () => {
    const app = await buildApp(locationRoutes, "/v1/location");
    const token = app.jwt.sign({ sub: "parent-1", purpose: "password_reset" });

    const res = await app.inject({
      method: "POST",
      url: "/v1/location/ping",
      headers: { authorization: `Bearer ${token}` },
      payload: PING,
    });
    expect(res.statusCode).toBe(401);
    expect(prismaMock.locationPing.create).not.toHaveBeenCalled();
    await app.close();
  });

  it("rejects a JWT with an unknown role (401)", async () => {
    const app = await buildApp(locationRoutes, "/v1/location");
    const token = app.jwt.sign({ sub: "svc-1", role: "service", familyId: "fam-1" });

    const res = await app.inject({
      method: "POST",
      url: "/v1/location/ping",
      headers: { authorization: `Bearer ${token}` },
      payload: PING,
    });
    expect(res.statusCode).toBe(401);
    expect(prismaMock.locationPing.create).not.toHaveBeenCalled();
    await app.close();
  });

  // Plan 2.7 F4 (Claude, #329, 2026-10-23): a location ping comes from the child's device. A parent JWT
  // (any family role, family claim or not) is refused with 403 device_role_required before the body is
  // read, so nothing is stored and no geofence (or routine) is evaluated. These replace the former
  // parent-ping tests ("accepts a parent ping … (201)", "parent-supplied deviceId … device_mismatch",
  // "… device_revoked for a parent-supplied deviceId"): the set of refused callers only grew.
  it("refuses a parent ping for a child of their own family (403 device_role_required) and stores nothing", async () => {
    const app = await buildApp(locationRoutes, "/v1/location");

    const res = await app.inject({
      method: "POST",
      url: "/v1/location/ping",
      headers: authHeader(app, "fam-1"),
      payload: PING,
    });
    expect(res.statusCode).toBe(403);
    expect(res.json().error).toBe("device_role_required");
    expect(prismaMock.child.findUnique).not.toHaveBeenCalled();
    expect(prismaMock.geofence.findMany).not.toHaveBeenCalled();
    expect(prismaMock.locationPing.create).not.toHaveBeenCalled();
    await app.close();
  });

  it("refuses every family role, with or without a family claim (403 device_role_required)", async () => {
    const app = await buildApp(locationRoutes, "/v1/location");
    const tokens = [
      app.jwt.sign({ sub: "owner-1", familyId: "fam-1", role: "parent", familyRole: "owner" }),
      app.jwt.sign({ sub: "co-1", familyId: "fam-1", role: "parent", familyRole: "co-parent" }),
      app.jwt.sign({ sub: "guardian-1", familyId: "fam-1", role: "parent", familyRole: "guardian" }),
      app.jwt.sign({ sub: "parent-1", role: "parent" }),
    ];
    for (const token of tokens) {
      const res = await app.inject({
        method: "POST",
        url: "/v1/location/ping",
        headers: { authorization: `Bearer ${token}` },
        payload: PING,
      });
      expect(res.statusCode).toBe(403);
      expect(res.json().error).toBe("device_role_required");
    }
    expect(prismaMock.locationPing.create).not.toHaveBeenCalled();
    await app.close();
  });

  it("keeps the family check for a device token whose family does not own the child (403 forbidden)", async () => {
    const app = await buildApp(locationRoutes, "/v1/location");
    prismaMock.child.findUnique.mockResolvedValue({ id: CHILD_ID, familyId: "fam-2" });

    const res = await app.inject({
      method: "POST",
      url: "/v1/location/ping",
      headers: deviceHeader(app, { deviceId: DEVICE_ID, childId: CHILD_ID, familyId: "fam-1" }),
      payload: PING,
    });
    expect(res.statusCode).toBe(403);
    expect(res.json().error).toBe("forbidden");
    expect(prismaMock.locationPing.create).not.toHaveBeenCalled();
    await app.close();
  });

  it("accepts the device's own ping (201) and files it under the token's device and child", async () => {
    const app = await buildApp(locationRoutes, "/v1/location");

    const res = await app.inject({
      method: "POST",
      url: "/v1/location/ping",
      headers: deviceHeader(app, { deviceId: DEVICE_ID, childId: CHILD_ID, familyId: "fam-1" }),
      payload: PING,
    });
    expect(res.statusCode).toBe(201);
    expect(prismaMock.locationPing.create).toHaveBeenCalledWith({
      data: expect.objectContaining({ childId: CHILD_ID, deviceId: DEVICE_ID }),
    });
    await app.close();
  });

  it("refuses a device token whose body names another device (403 device_mismatch)", async () => {
    const app = await buildApp(locationRoutes, "/v1/location");

    const res = await app.inject({
      method: "POST",
      url: "/v1/location/ping",
      headers: deviceHeader(app, { deviceId: "device-other", childId: CHILD_ID, familyId: "fam-1" }),
      payload: PING,
    });
    expect(res.statusCode).toBe(403);
    expect(res.json().error).toBe("device_mismatch");
    expect(prismaMock.locationPing.create).not.toHaveBeenCalled();
    await app.close();
  });
});

describe("device-token child scoping on location reads", () => {
  beforeEach(() => {
    resetPrismaMock();
  });

  it("lets a device read its own child's latest ping (200)", async () => {
    const app = await buildApp(locationRoutes, "/v1/location");
    prismaMock.child.findUnique.mockResolvedValue({ id: CHILD_ID, familyId: "fam-1" });
    prismaMock.locationPing.findFirst.mockResolvedValue({ id: "ping-7" });

    const res = await app.inject({
      method: "GET",
      url: `/v1/location/${CHILD_ID}/latest`,
      headers: deviceHeader(app),
    });
    expect(res.statusCode).toBe(200);
    await app.close();
  });

  it("forbids a device from reading a sibling child's latest ping (403 cross_child_forbidden)", async () => {
    const app = await buildApp(locationRoutes, "/v1/location");
    prismaMock.child.findUnique.mockResolvedValue({ id: SIBLING_ID, familyId: "fam-1" });
    prismaMock.locationPing.findFirst.mockResolvedValue({ id: "ping-8" });

    const res = await app.inject({
      method: "GET",
      url: `/v1/location/${SIBLING_ID}/latest`,
      headers: deviceHeader(app),
    });
    expect(res.statusCode).toBe(403);
    expect(res.json().error).toBe("cross_child_forbidden");
    expect(prismaMock.locationPing.findFirst).not.toHaveBeenCalled();
    await app.close();
  });

  it("lets a device read its own child's history (200) and forbids a sibling's (403)", async () => {
    const app = await buildApp(locationRoutes, "/v1/location");
    prismaMock.child.findUnique.mockImplementation(async ({ where }: { where: { id: string } }) => ({
      id: where.id,
      familyId: "fam-1",
    }));
    prismaMock.locationPing.findMany.mockResolvedValue([]);

    const own = await app.inject({
      method: "GET",
      url: `/v1/location/${CHILD_ID}/history`,
      headers: deviceHeader(app),
    });
    expect(own.statusCode).toBe(200);

    const sibling = await app.inject({
      method: "GET",
      url: `/v1/location/${SIBLING_ID}/history`,
      headers: deviceHeader(app),
    });
    expect(sibling.statusCode).toBe(403);
    expect(sibling.json().error).toBe("cross_child_forbidden");
    await app.close();
  });

  it("lets a device list its own child's geofences (200) and forbids a sibling's (403)", async () => {
    const app = await buildApp(locationRoutes, "/v1/location");
    prismaMock.child.findUnique.mockImplementation(async ({ where }: { where: { id: string } }) => ({
      id: where.id,
      familyId: "fam-1",
    }));
    prismaMock.geofence.findMany.mockResolvedValue([]);

    const own = await app.inject({
      method: "GET",
      url: `/v1/location/geofences/${CHILD_ID}`,
      headers: deviceHeader(app),
    });
    expect(own.statusCode).toBe(200);

    const sibling = await app.inject({
      method: "GET",
      url: `/v1/location/geofences/${SIBLING_ID}`,
      headers: deviceHeader(app),
    });
    expect(sibling.statusCode).toBe(403);
    expect(sibling.json().error).toBe("cross_child_forbidden");
    await app.close();
  });

  it("still lets a parent read any child in the family (200)", async () => {
    const app = await buildApp(locationRoutes, "/v1/location");
    prismaMock.child.findUnique.mockResolvedValue({ id: SIBLING_ID, familyId: "fam-1" });
    prismaMock.locationPing.findFirst.mockResolvedValue({ id: "ping-9" });

    const res = await app.inject({
      method: "GET",
      url: `/v1/location/${SIBLING_ID}/latest`,
      headers: authHeader(app, "fam-1"),
    });
    expect(res.statusCode).toBe(200);
    await app.close();
  });
});
