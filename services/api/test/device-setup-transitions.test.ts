import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { completeDeviceSetupIfReady, evaluateDeviceSetupIncomplete, runDeviceSetupCheck } from "../src/lib/deviceSetupTransitions.js";
import { runDeviceSilenceCheck } from "../src/jobs/deviceSilence.js";
import { deviceRoutes } from "../src/routes/devices.js";
import { buildApp, deviceHeader, prismaMock, resetPrismaMock } from "./helpers.js";

vi.mock("../src/db.js", async () => ({ prisma: (await import("./helpers.js")).prismaMock }));
vi.mock("ioredis", async () => ({ Redis: (await import("./helpers.js")).MockRedis }));

const START = new Date("2026-11-25T01:00:00.000Z");
const EXPIRY = new Date(START.getTime() + 30 * 60_000);
const COMPLETED_AT = new Date(START.getTime() + 1_000);
const ALL_REQUIRED = {
  accessibility: "granted",
  usage_access: "granted",
  overlay: "granted",
  device_admin: "granted",
  web_filter: "granted",
  location: "granted",
  private_dns: "granted",
} as const;
const COMPLETE = {
  client: { app: "child-android", version: "0.2.0", build: 42, flavour: "full" },
  grants: { ...ALL_REQUIRED, battery: "missing", notification_listener: "granted" },
  features: {},
};

function device(overrides: Record<string, unknown> = {}) {
  return {
    id: "dev-1",
    childId: "child-1",
    platform: "android",
    model: "Test Phone",
    pairedAt: START,
    setupCompletedAt: null,
    capabilities: COMPLETE,
    child: { familyId: "fam-1", displayName: "Child One" },
    ...overrides,
  };
}

describe("setup completion and timeout transitions (#1127)", () => {
  beforeEach(() => {
    resetPrismaMock();
    prismaMock.alert.create.mockImplementation(async ({ data }) => ({ id: "alert-created", ...data }));
    // #1230: the setup-notice write holds the Device row; the lock read sees an open setup.
    prismaMock.$queryRaw.mockImplementation(async (strings: TemplateStringsArray) =>
      Array.from(strings ?? []).join("").includes("FOR NO KEY UPDATE") ? [{ setupCompletedAt: null }] : []);
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it("completes once from a valid report, including recommended grants still missing", async () => {
    prismaMock.device.updateMany.mockResolvedValue({ count: 1 });
    const row = device();
    expect(await completeDeviceSetupIfReady(row, COMPLETE, START)).toBe(true);
    expect(prismaMock.device.updateMany).toHaveBeenCalledWith({
      where: { id: "dev-1", setupCompletedAt: null },
      data: { setupCompletedAt: START },
    });
    expect(prismaMock.alert.create).toHaveBeenCalledWith({
      data: expect.objectContaining({
        dedupeKey: `setup_complete|dev-1|${START.toISOString()}`,
        metadata: expect.objectContaining({ type: "setup_complete", bodyKey: "alertBodySetupCompleted" }),
      }),
    });
    prismaMock.alert.findFirst.mockResolvedValue({ id: "existing-complete", attemptCount: 1 });
    expect(await completeDeviceSetupIfReady(device({ setupCompletedAt: START }), COMPLETE, START)).toBe(false);
    expect(prismaMock.alert.create).toHaveBeenCalledTimes(1);
  });

  it("does not complete with a required grant missing", async () => {
    const incomplete = { ...COMPLETE, grants: { ...COMPLETE.grants, overlay: "missing" } };
    expect(await completeDeviceSetupIfReady(device(), incomplete, START)).toBe(false);
    expect(prismaMock.device.updateMany).not.toHaveBeenCalled();
    expect(prismaMock.alert.create).not.toHaveBeenCalled();
  });

  it("does not alert a migration-backfilled device on its next all-ready report", async () => {
    expect(await completeDeviceSetupIfReady(device({ setupCompletedAt: START }), COMPLETE, COMPLETED_AT)).toBe(false);
    expect(prismaMock.device.updateMany).not.toHaveBeenCalled();
    expect(prismaMock.alert.findFirst).not.toHaveBeenCalled();
    expect(prismaMock.alert.create).not.toHaveBeenCalled();
  });

  it("rolls completion back when the protected alert cannot be written", async () => {
    prismaMock.device.updateMany.mockResolvedValue({ count: 1 });
    prismaMock.alert.create.mockRejectedValue(new Error("synthetic alert write failure"));
    await expect(completeDeviceSetupIfReady(device(), COMPLETE, START)).rejects.toThrow("synthetic alert write failure");
    expect(prismaMock.device.updateMany).toHaveBeenLastCalledWith({
      where: { id: "dev-1", setupCompletedAt: START },
      data: { setupCompletedAt: null },
    });
  });

  it("retries the protected alert after both its first write and rollback fail", async () => {
    prismaMock.device.updateMany
      .mockResolvedValueOnce({ count: 1 })
      .mockRejectedValueOnce(new Error("synthetic rollback failure"));
    prismaMock.alert.create
      .mockRejectedValueOnce(new Error("synthetic alert write failure"))
      .mockResolvedValueOnce({ id: "protected-alert" });
    await expect(completeDeviceSetupIfReady(device(), COMPLETE, COMPLETED_AT)).rejects.toThrow("synthetic alert write failure");

    expect(await completeDeviceSetupIfReady(device({ setupCompletedAt: COMPLETED_AT }), COMPLETE, COMPLETED_AT)).toBe(true);
    expect(prismaMock.alert.create).toHaveBeenCalledTimes(2);
    expect(prismaMock.device.updateMany).toHaveBeenCalledTimes(2);
    expect(prismaMock.device.updateMany).toHaveBeenLastCalledWith({
      where: { id: "dev-1", setupCompletedAt: COMPLETED_AT },
      data: { setupCompletedAt: null },
    });
  });

  it("dedupes the timeout across evaluations and names the last reported missing steps", async () => {
    const row = device({ capabilities: { ...COMPLETE, grants: { ...COMPLETE.grants, overlay: "missing", accessibility: "missing" } } });
    // First evaluation: no row under the shared key (checked by the transition, then by raiseAlertOnce).
    // Second evaluation: the row exists with the same missing steps, so nothing is rewritten or paged.
    prismaMock.alert.findFirst
      .mockResolvedValueOnce(null)
      .mockResolvedValueOnce(null)
      .mockResolvedValueOnce({
        id: "existing-incomplete",
        attemptCount: 1,
        heldDuringSetup: false,
        metadata: { serverReminder: true, missing: ["accessibility", "overlay"] },
      });
    const first = await evaluateDeviceSetupIncomplete(row, EXPIRY);
    const second = await evaluateDeviceSetupIncomplete(row, EXPIRY);
    expect(first).toEqual({ due: true, deduplicated: false });
    expect(second).toEqual({ due: true, deduplicated: true });
    expect(prismaMock.alert.create).toHaveBeenCalledTimes(1);
    expect(prismaMock.alert.create).toHaveBeenCalledWith({
      data: expect.objectContaining({
        dedupeKey: "setup_incomplete:dev-1",
        metadata: expect.objectContaining({
          type: "setup_incomplete",
          bodyKey: "alertBodySetupIncomplete",
          bodyParams: { childName: "Child One", count: 2, steps: "accessibility, overlay" },
        }),
      }),
    });
  });

  it("runs expired setup evaluation in the existing silence runner without changing its result shape", async () => {
    prismaMock.device.findMany.mockImplementation(async ({ where }) =>
      where.status === "online" ? [] : [device()]);
    const result = await runDeviceSilenceCheck(EXPIRY, { DEVICE_SILENT_MINUTES: "30" } as NodeJS.ProcessEnv);
    expect(result).toEqual({ checked: 0, alerted: [] });
    expect(prismaMock.alert.create).toHaveBeenCalledWith({
      data: expect.objectContaining({ dedupeKey: "setup_incomplete:dev-1" }),
    });
  });

  it("returns only newly alerted ids from the standalone setup check", async () => {
    prismaMock.device.findMany.mockResolvedValue([device()]);
    prismaMock.alert.findFirst
      .mockResolvedValueOnce(null)
      .mockResolvedValueOnce(null)
      .mockResolvedValueOnce({ id: "existing", attemptCount: 1, heldDuringSetup: false, metadata: { serverReminder: true, missing: [] } });
    expect(await runDeviceSetupCheck(EXPIRY)).toEqual({ checked: 1, alerted: ["dev-1"] });
    expect(await runDeviceSetupCheck(EXPIRY)).toEqual({ checked: 1, alerted: [] });
  });

  it("completes from authenticated telemetry and evaluates timeout on the next device poll", async () => {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    const row = device({ lastSeen: START });
    prismaMock.device.findUnique.mockResolvedValue(row);
    prismaMock.device.updateMany.mockImplementation(async ({ where }) =>
      where.setupCompletedAt === null ? { count: 1 } : { count: 0 });
    const telemetry = await app.inject({
      method: "POST",
      url: "/v1/devices/dev-1/telemetry",
      headers: deviceHeader(app),
      payload: { batteryPct: 80, capabilities: COMPLETE },
    });
    expect(telemetry.statusCode).toBe(202);
    expect(prismaMock.alert.create).toHaveBeenCalledWith({
      data: expect.objectContaining({ dedupeKey: `setup_complete|dev-1|${START.toISOString()}` }),
    });

    // A separate device is already 30 minutes old and still incomplete; its command poll must share
    // the same timeout evaluator rather than waiting for the scheduler.
    prismaMock.device.findUnique.mockResolvedValue(device({
      capabilities: { ...COMPLETE, grants: { ...COMPLETE.grants, accessibility: "missing" } },
    }));
    prismaMock.$queryRaw.mockImplementation(async (strings: TemplateStringsArray) =>
      Array.from(strings ?? []).join("").includes("FOR NO KEY UPDATE") ? [{ setupCompletedAt: null }] : []);
    const logWarn = vi.spyOn(app.log, "warn");
    const poll = await app.inject({ method: "GET", url: "/v1/devices/dev-1/commands", headers: deviceHeader(app) });
    expect(poll.statusCode).toBe(200);
    expect(logWarn).not.toHaveBeenCalled();
    expect(prismaMock.alert.create).toHaveBeenCalledWith({
      data: expect.objectContaining({ dedupeKey: "setup_incomplete:dev-1" }),
    });
    await app.close();
  });
});
