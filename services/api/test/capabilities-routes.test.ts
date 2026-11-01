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

/**
 * ADR-0034 PR 1a at the route, not only in the library.
 *
 * The unit rows prove the schema and the rules; these prove the **route** behaves the way the claim is
 * written — a bad report costs its field and nothing else, a device clock never becomes the server's, and
 * a command the build cannot run is recorded failed rather than queued.
 */

const DEVICE = { id: "dev-1", childId: "child-1", child: { familyId: "fam-1" } };

function capabilities(overrides: Record<string, unknown> = {}) {
  return {
    client: { app: "child-android", version: "0.2.0", build: 2, flavour: "full" },
    grants: { accessibility: "granted", overlay: "missing" },
    features: { lock_screen: "ready", call_sms_log: "ready" },
    ...overrides,
  };
}

describe("ADR-0034 claim 9 — a bad report costs the field, not the upload", () => {
  beforeEach(() => resetPrismaMock());

  it("an over-capabilities upload answers 400 for that field and still stores the rest", async () => {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    prismaMock.device.findUnique.mockResolvedValue(DEVICE);
    prismaMock.device.update.mockResolvedValue(DEVICE);

    const res = await app.inject({
      method: "POST",
      url: "/v1/devices/dev-1/telemetry",
      headers: deviceHeader(app),
      payload: { batteryPct: 42, capabilities: { client: { app: "child-android" } } }, // malformed on purpose
    });

    expect(res.statusCode).toBe(400);
    expect(res.json().error).toBe("invalid_capabilities");
    expect(res.json().fieldErrors.capabilities).toBeTruthy();
    expect(res.json().accepted).toBe(true);
    // The rest of the upload was stored: the device row is updated with the telemetry it carries.
    expect(prismaMock.device.update).toHaveBeenCalledWith(
      expect.objectContaining({ data: expect.objectContaining({ batteryPct: 42, status: "online" }) }),
    );
    // And the bad report was NOT written.
    const written = prismaMock.device.update.mock.calls.at(-1)?.[0]?.data ?? {};
    expect(written.capabilities).toBeUndefined();
  });

  it("a valid report is stored with the server's receipt time", async () => {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    prismaMock.device.findUnique.mockResolvedValue(DEVICE);
    prismaMock.device.update.mockResolvedValue(DEVICE);

    const res = await app.inject({
      method: "POST",
      url: "/v1/devices/dev-1/telemetry",
      headers: deviceHeader(app),
      payload: { capabilities: capabilities() },
    });

    expect(res.statusCode).toBe(202);
    const written = prismaMock.device.update.mock.calls.at(-1)?.[0]?.data ?? {};
    expect(written.capabilities).toMatchObject({ client: { app: "child-android", flavour: "full" } });
    expect(written.capabilitiesReportedAt).toBeInstanceOf(Date);
  });

  it("claim 11 — a timestamp inside the report neither passes validation nor becomes the receipt time", async () => {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    prismaMock.device.findUnique.mockResolvedValue(DEVICE);
    prismaMock.device.update.mockResolvedValue(DEVICE);

    const res = await app.inject({
      method: "POST",
      url: "/v1/devices/dev-1/telemetry",
      headers: deviceHeader(app),
      payload: { capabilities: capabilities({ reportedAt: "2030-01-01T00:00:00.000Z", timestamp: 1 }) },
    });

    // `.strict()` refuses the device's own clock, so the report is dropped rather than future-dated.
    expect(res.statusCode).toBe(400);
    const written = prismaMock.device.update.mock.calls.at(-1)?.[0]?.data ?? {};
    expect(written.capabilities).toBeUndefined();
    expect(written.capabilitiesReportedAt).toBeUndefined();
  });

  it("an upload without the field leaves the stored report alone", async () => {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    prismaMock.device.findUnique.mockResolvedValue(DEVICE);
    prismaMock.device.update.mockResolvedValue(DEVICE);

    const res = await app.inject({
      method: "POST",
      url: "/v1/devices/dev-1/telemetry",
      headers: deviceHeader(app),
      payload: { batteryPct: 10 },
    });

    expect(res.statusCode).toBe(202);
    const written = prismaMock.device.update.mock.calls.at(-1)?.[0]?.data ?? {};
    expect(written.capabilities).toBeUndefined();
    expect(written.capabilitiesReportedAt).toBeUndefined();
  });
});

describe("ADR-0034 claim 13 — a command the build cannot run is failed, not queued", () => {
  beforeEach(() => resetPrismaMock());

  it("a lock to an iPhone is recorded failed with not_supported, whatever the report's age", async () => {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    prismaMock.device.findUnique.mockResolvedValue({
      ...DEVICE,
      // Ten hours old: the freshness guard never fires, so only the build table can refuse this.
      capabilities: capabilities({ client: { app: "child-ios", version: "0.1.0", build: 1, flavour: "testflight" }, features: {} }),
      capabilitiesReportedAt: new Date(Date.now() - 10 * 60 * 60 * 1000),
    });

    const res = await app.inject({
      method: "POST",
      url: "/v1/devices/dev-1/command",
      headers: authHeader(app),
      payload: { command: "lock" },
    });

    expect(res.statusCode).toBe(200);
    expect(res.json()).toMatchObject({ published: false, status: "failed", reason: "not_supported" });
    expect(prismaMock.deviceCommand.create).toHaveBeenCalledWith(
      expect.objectContaining({ data: expect.objectContaining({ type: "lock", status: "failed" }) }),
    );
  });

  it("a lock with a FRESH unavailable report is failed with the feature's own reason", async () => {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    prismaMock.device.findUnique.mockResolvedValue({
      ...DEVICE,
      capabilities: capabilities({ features: { lock_screen: "unavailable" } }),
      capabilitiesReportedAt: new Date(),
    });

    const res = await app.inject({
      method: "POST",
      url: "/v1/devices/dev-1/command",
      headers: authHeader(app),
      payload: { command: "lock" },
    });

    expect(res.json()).toMatchObject({ published: false, status: "failed", reason: "lock_screen_unavailable" });
  });

  it("the same lock at 21 minutes is queued, and the phone answers it", async () => {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    prismaMock.device.findUnique.mockResolvedValue({
      ...DEVICE,
      capabilities: capabilities({ features: { lock_screen: "unavailable" } }),
      capabilitiesReportedAt: new Date(Date.now() - 21 * 60 * 1000),
    });

    const res = await app.inject({
      method: "POST",
      url: "/v1/devices/dev-1/command",
      headers: authHeader(app),
      payload: { command: "lock" },
    });

    expect(res.json()).toMatchObject({ published: true, status: "pending" });
  });

  it("a degraded report queues", async () => {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    prismaMock.device.findUnique.mockResolvedValue({
      ...DEVICE,
      capabilities: capabilities({ features: { lock_screen: "degraded" } }),
      capabilitiesReportedAt: new Date(),
    });

    const res = await app.inject({
      method: "POST",
      url: "/v1/devices/dev-1/command",
      headers: authHeader(app),
      payload: { command: "lock" },
    });

    expect(res.json()).toMatchObject({ published: true, status: "pending" });
  });
});
