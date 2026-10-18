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

  it("rejects a parent token without a familyId (401)", async () => {
    const app = await buildApp(locationRoutes, "/v1/location");
    const token = app.jwt.sign({ sub: "parent-1", role: "parent" });

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

  it("keeps the family check for a parent from another family (403)", async () => {
    const app = await buildApp(locationRoutes, "/v1/location");
    prismaMock.child.findUnique.mockResolvedValue({ id: CHILD_ID, familyId: "fam-2" });

    const res = await app.inject({
      method: "POST",
      url: "/v1/location/ping",
      headers: authHeader(app, "fam-1"),
      payload: PING,
    });
    expect(res.statusCode).toBe(403);
    expect(prismaMock.locationPing.create).not.toHaveBeenCalled();
    await app.close();
  });

  it("accepts a parent ping for a child in their own family (201)", async () => {
    const app = await buildApp(locationRoutes, "/v1/location");

    const res = await app.inject({
      method: "POST",
      url: "/v1/location/ping",
      headers: authHeader(app, "fam-1"),
      payload: PING,
    });
    expect(res.statusCode).toBe(201);
    expect(prismaMock.locationPing.create).toHaveBeenCalledWith({
      data: expect.objectContaining({ childId: CHILD_ID, deviceId: DEVICE_ID }),
    });
    await app.close();
  });

  it("rejects a parent-supplied deviceId that belongs to another child (403 device_mismatch)", async () => {
    const app = await buildApp(locationRoutes, "/v1/location");
    prismaMock.device.findUnique.mockResolvedValue({ id: DEVICE_ID, childId: SIBLING_ID });

    const res = await app.inject({
      method: "POST",
      url: "/v1/location/ping",
      headers: authHeader(app, "fam-1"),
      payload: PING,
    });
    expect(res.statusCode).toBe(403);
    expect(res.json().error).toBe("device_mismatch");
    expect(prismaMock.locationPing.create).not.toHaveBeenCalled();
    await app.close();
  });

  it("keeps 401 device_revoked for a parent-supplied deviceId with no row (existing contract)", async () => {
    const app = await buildApp(locationRoutes, "/v1/location");
    prismaMock.device.findUnique.mockResolvedValue(null);

    const res = await app.inject({
      method: "POST",
      url: "/v1/location/ping",
      headers: authHeader(app, "fam-1"),
      payload: PING,
    });
    expect(res.statusCode).toBe(401);
    expect(res.json().error).toBe("device_revoked");
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
