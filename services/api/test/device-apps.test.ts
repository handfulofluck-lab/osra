import { beforeEach, describe, expect, it, vi } from "vitest";
import { deviceRoutes } from "../src/routes/devices.js";
import { MockRedis, authHeader, buildApp, deviceHeader, prismaMock, resetPrismaMock } from "./helpers.js";

vi.mock("../src/db.js", async () => {
  const { prismaMock } = await import("./helpers.js");
  return { prisma: prismaMock };
});
vi.mock("ioredis", async () => {
  const { MockRedis } = await import("./helpers.js");
  return { Redis: MockRedis };
});

// Roadmap 3.4: the installed-launchable-app inventory. The route is an agent write
// (`requireFamily` + `requireOwnDevice`, same as /telemetry) and a parent read
// (`requireParent` + the `rules` permission + `requireFamily`), so both halves are pinned here.
const DEVICE = {
  id: "dev-1",
  childId: "child-1",
  child: { familyId: "fam-1" },
  appsReportedAt: new Date("2026-10-19T08:30:00.000Z"),
  appsVersion: 1,
};

const PACKAGE = "com.example.game";

describe("installed app inventory — agent write", () => {
  beforeEach(() => {
    resetPrismaMock();
  });

  it("stores a deduped, trimmed report and stamps the device (202)", async () => {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    prismaMock.device.findUnique.mockResolvedValue(DEVICE);

    const res = await app.inject({
      method: "POST",
      url: "/v1/devices/dev-1/apps",
      headers: deviceHeader(app),
      payload: {
        version: 1,
        apps: [
          { packageId: PACKAGE, label: "  Game  ", isSystem: false },
          // Duplicate package: the first occurrence wins (the list builder on the device already
          // dedupes; the server repeats the rule so a hand-written payload cannot double the rows).
          { packageId: PACKAGE, label: "Game duplicate", isSystem: true },
          // A blank label falls back to the package id, so the parent picker never shows an empty row.
          { packageId: "com.android.settings", label: "   ", isSystem: true },
        ],
      },
    });

    expect(res.statusCode).toBe(202);
    expect(res.json()).toMatchObject({ accepted: true, count: 2, version: 1 });
    expect(prismaMock.deviceApp.deleteMany).toHaveBeenCalledWith({ where: { deviceId: "dev-1" } });
    expect(prismaMock.deviceApp.createMany).toHaveBeenCalledWith({
      data: [
        { deviceId: "dev-1", packageId: PACKAGE, label: "Game", isSystem: false },
        { deviceId: "dev-1", packageId: "com.android.settings", label: "com.android.settings", isSystem: true },
      ],
    });
    expect(prismaMock.device.update).toHaveBeenCalledWith(
      expect.objectContaining({
        where: { id: "dev-1" },
        data: expect.objectContaining({
          appsVersion: 1,
          appsReportedAt: expect.any(Date),
          lastSeen: expect.any(Date),
        }),
      }),
    );
    await app.close();
  });

  it("replaces the previous list and an empty report clears it", async () => {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    prismaMock.device.findUnique.mockResolvedValue(DEVICE);

    const cleared = await app.inject({
      method: "POST",
      url: "/v1/devices/dev-1/apps",
      headers: deviceHeader(app),
      payload: { version: 1, apps: [] },
    });
    expect(cleared.statusCode).toBe(202);
    expect(cleared.json()).toMatchObject({ accepted: true, count: 0, version: 1 });
    expect(prismaMock.deviceApp.deleteMany).toHaveBeenCalledWith({ where: { deviceId: "dev-1" } });
    expect(prismaMock.deviceApp.createMany).not.toHaveBeenCalled();
    expect(prismaMock.device.update).toHaveBeenCalled();
    await app.close();
  });

  it("bounds the payload: 501 apps, a 101-character label, an invalid package id and version 2 -> 400", async () => {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    prismaMock.device.findUnique.mockResolvedValue(DEVICE);

    const tooMany = await app.inject({
      method: "POST",
      url: "/v1/devices/dev-1/apps",
      headers: deviceHeader(app),
      payload: {
        version: 1,
        apps: Array.from({ length: 501 }, (_, i) => ({ packageId: `com.example.app${i}`, label: `App ${i}`, isSystem: false })),
      },
    });
    expect(tooMany.statusCode).toBe(400);

    const longLabel = await app.inject({
      method: "POST",
      url: "/v1/devices/dev-1/apps",
      headers: deviceHeader(app),
      payload: { version: 1, apps: [{ packageId: PACKAGE, label: "x".repeat(101), isSystem: false }] },
    });
    expect(longLabel.statusCode).toBe(400);

    const badPackage = await app.inject({
      method: "POST",
      url: "/v1/devices/dev-1/apps",
      headers: deviceHeader(app),
      payload: { version: 1, apps: [{ packageId: "com.example game", label: "Game", isSystem: false }] },
    });
    expect(badPackage.statusCode).toBe(400);

    const badVersion = await app.inject({
      method: "POST",
      url: "/v1/devices/dev-1/apps",
      headers: deviceHeader(app),
      payload: { version: 2, apps: [] },
    });
    expect(badVersion.statusCode).toBe(400);

    expect(prismaMock.deviceApp.deleteMany).not.toHaveBeenCalled();
    expect(prismaMock.deviceApp.createMany).not.toHaveBeenCalled();
    await app.close();
  });

  it("refuses a device writing another device's inventory (403) and a foreign family (403)", async () => {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    prismaMock.device.findUnique.mockResolvedValue(DEVICE);

    const sibling = await app.inject({
      method: "POST",
      url: "/v1/devices/dev-1/apps",
      headers: deviceHeader(app, { deviceId: "dev-9", childId: "child-1", familyId: "fam-1" }),
      payload: { version: 1, apps: [] },
    });
    expect(sibling.statusCode).toBe(403);
    expect(sibling.json()).toEqual({ error: "forbidden" });

    prismaMock.device.findUnique.mockResolvedValue({ ...DEVICE, child: { familyId: "fam-2" } });
    const foreign = await app.inject({
      method: "POST",
      url: "/v1/devices/dev-1/apps",
      headers: deviceHeader(app),
      payload: { version: 1, apps: [] },
    });
    expect(foreign.statusCode).toBe(403);
    expect(prismaMock.deviceApp.deleteMany).not.toHaveBeenCalled();
    await app.close();
  });

  it("stops collection when parental consent is withdrawn (428)", async () => {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    prismaMock.device.findUnique.mockResolvedValue(DEVICE);
    prismaMock.consentRecord.findFirst.mockResolvedValue(null);

    const res = await app.inject({
      method: "POST",
      url: "/v1/devices/dev-1/apps",
      headers: deviceHeader(app),
      payload: { version: 1, apps: [{ packageId: PACKAGE, label: "Game", isSystem: false }] },
    });
    expect(res.statusCode).toBe(428);
    expect(prismaMock.deviceApp.deleteMany).not.toHaveBeenCalled();
    await app.close();
  });
});

describe("installed app inventory — parent read", () => {
  beforeEach(() => {
    resetPrismaMock();
  });

  it("returns the family-scoped list with the contract version and report time", async () => {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    prismaMock.device.findUnique.mockResolvedValue(DEVICE);
    prismaMock.deviceApp.findMany.mockResolvedValue([
      { packageId: PACKAGE, label: "Game", isSystem: false },
      { packageId: "com.android.settings", label: "Settings", isSystem: true },
    ]);

    const res = await app.inject({ method: "GET", url: "/v1/devices/dev-1/apps", headers: authHeader(app) });

    expect(res.statusCode).toBe(200);
    expect(res.json()).toEqual({
      deviceId: "dev-1",
      version: 1,
      reportedAt: "2026-10-19T08:30:00.000Z",
      count: 2,
      apps: [
        { packageId: PACKAGE, label: "Game", isSystem: false },
        { packageId: "com.android.settings", label: "Settings", isSystem: true },
      ],
    });
    expect(prismaMock.deviceApp.findMany).toHaveBeenCalledWith({
      where: { deviceId: "dev-1" },
      select: { packageId: true, label: true, isSystem: true },
      orderBy: [{ label: "asc" }, { packageId: "asc" }],
    });
    await app.close();
  });

  it("returns an empty list and no report time for a device that has never reported", async () => {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    prismaMock.device.findUnique.mockResolvedValue({ ...DEVICE, appsReportedAt: null, appsVersion: null });
    prismaMock.deviceApp.findMany.mockResolvedValue([]);

    const res = await app.inject({ method: "GET", url: "/v1/devices/dev-1/apps", headers: authHeader(app) });
    expect(res.statusCode).toBe(200);
    expect(res.json()).toMatchObject({ deviceId: "dev-1", version: 1, reportedAt: null, count: 0, apps: [] });
    await app.close();
  });

  it("keeps family isolation (403) and parent-only role (403)", async () => {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    prismaMock.device.findUnique.mockResolvedValue({ ...DEVICE, child: { familyId: "fam-2" } });

    const foreign = await app.inject({ method: "GET", url: "/v1/devices/dev-1/apps", headers: authHeader(app) });
    expect(foreign.statusCode).toBe(403);

    prismaMock.device.findUnique.mockResolvedValue(DEVICE);
    const deviceToken = await app.inject({ method: "GET", url: "/v1/devices/dev-1/apps", headers: deviceHeader(app) });
    expect(deviceToken.statusCode).toBe(403);
    expect(deviceToken.json()).toEqual({ error: "parent_role_required" });

    const anonymous = await app.inject({ method: "GET", url: "/v1/devices/dev-1/apps" });
    expect(anonymous.statusCode).toBe(401);
    await app.close();
  });

  it("requires the rules permission: a co-parent without it gets 403, with it 200", async () => {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    prismaMock.device.findUnique.mockResolvedValue(DEVICE);
    prismaMock.deviceApp.findMany.mockResolvedValue([]);

    prismaMock.parent.findUnique.mockResolvedValue({ id: "p-co", familyId: "fam-1", role: "co-parent", permissions: ["alerts"] });
    const denied = await app.inject({ method: "GET", url: "/v1/devices/dev-1/apps", headers: authHeader(app, "fam-1", "p-co") });
    expect(denied.statusCode).toBe(403);
    expect(denied.json()).toEqual({ error: "permission_required", permission: "rules" });

    prismaMock.parent.findUnique.mockResolvedValue({ id: "p-co", familyId: "fam-1", role: "co-parent", permissions: ["rules"] });
    const allowed = await app.inject({ method: "GET", url: "/v1/devices/dev-1/apps", headers: authHeader(app, "fam-1", "p-co") });
    expect(allowed.statusCode).toBe(200);
    await app.close();
  });
});
