import { readFileSync } from "node:fs";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { getRedis } from "../src/redis.js";
import {
  SILENT_MIN_SAFE_MINUTES,
  STATIONARY_PING_INTERVAL_MINUTES,
  TELEMETRY_INTERVAL_MINUTES,
  isSilent,
  resolveSilenceConfig,
  runDeviceSilenceCheck,
  silenceConfigWarning,
  silentAfterMinutes,
  startDeviceSilenceScheduler,
  stopDeviceSilenceScheduler,
} from "../src/jobs/deviceSilence.js";
import { deviceRoutes } from "../src/routes/devices.js";
import { MockRedis, buildApp, deviceHeader, prismaMock, resetPrismaMock } from "./helpers.js";

vi.mock("../src/db.js", async () => {
  const { prismaMock } = await import("./helpers.js");
  return { prisma: prismaMock };
});
vi.mock("ioredis", async () => {
  const { MockRedis } = await import("./helpers.js");
  return { Redis: MockRedis };
});
vi.mock("../src/lib/push/notify.js", () => ({ notifyParentsOfAlert: vi.fn(async () => undefined) }));
vi.mock("../src/realtime/gateway.js", () => ({ publishFamilyEvent: vi.fn(async () => undefined) }));

const NOW = new Date("2026-10-17T12:00:00.000Z");

describe("device-silence watch (plan 1.9 finding: a wiped agent cannot alert, the server must)", () => {
  beforeEach(() => resetPrismaMock());

  it("pure rule: online + unseen for longer than the window", () => {
    expect(isSilent("online", new Date(NOW.getTime() - 31 * 60_000), NOW, 30)).toBe(true);
    expect(isSilent("online", new Date(NOW.getTime() - 29 * 60_000), NOW, 30)).toBe(false);
    expect(isSilent("offline", new Date(NOW.getTime() - 3 * 3600_000), NOW, 30)).toBe(false);
    expect(isSilent("locked", new Date(NOW.getTime() - 3 * 3600_000), NOW, 30)).toBe(false);
    // Audit finding 4: `active` is not a value any writer produces. It used to be the rule's only
    // match, which is why the watch could never fire.
    expect(isSilent("active", new Date(NOW.getTime() - 3 * 3600_000), NOW, 30)).toBe(false);
    // Since #166 a 15-minute window is one telemetry interval and therefore too tight: it is raised
    // to the two-interval minimum. The full rule is pinned in the describe block below.
    expect(silentAfterMinutes({ DEVICE_SILENT_MINUTES: "15" } as NodeJS.ProcessEnv)).toBe(30);
    expect(silentAfterMinutes({ DEVICE_SILENT_MINUTES: "1" } as NodeJS.ProcessEnv)).toBe(30);
    expect(silentAfterMinutes({} as NodeJS.ProcessEnv)).toBe(30);
  });

  it("raises one critical tamper/device_silent alert per episode and flips the device to offline", async () => {
    const lastSeen = new Date(NOW.getTime() - 45 * 60_000);
    prismaMock.device.findMany.mockResolvedValue([
      { id: "dev-1", status: "online", lastSeen, childId: "child-1", model: "SM-F721B", child: { familyId: "fam-1", displayName: "Alex" } },
    ]);
    prismaMock.alert.create.mockImplementation(async ({ data }: { data: Record<string, unknown> }) => ({ id: "alert-1", ...data }));
    const redis = getRedis() as unknown as MockRedis;
    redis.set.mockResolvedValueOnce("OK");

    const run = await runDeviceSilenceCheck(NOW, { DEVICE_SILENT_MINUTES: "30" } as NodeJS.ProcessEnv);
    expect(run).toEqual({ checked: 1, alerted: ["dev-1"] });
    expect(prismaMock.device.update).toHaveBeenCalledWith({ where: { id: "dev-1" }, data: { status: "offline" } });
    expect(prismaMock.alert.create).toHaveBeenCalledWith(
      expect.objectContaining({
        data: expect.objectContaining({ category: "tamper", severity: "critical", deviceId: "dev-1", metadata: expect.objectContaining({ type: "device_silent" }) }),
      }),
    );
    expect(redis.set).toHaveBeenCalledWith(`jobs:device-silent:dev-1:${lastSeen.toISOString()}`, expect.any(String), "EX", 7 * 24 * 3600, "NX");

    // a second instance (or the next tick) sees the claim taken: no duplicate
    redis.set.mockResolvedValueOnce(null);
    const again = await runDeviceSilenceCheck(NOW, { DEVICE_SILENT_MINUTES: "30" } as NodeJS.ProcessEnv);
    expect(again.alerted).toEqual([]);
    expect(prismaMock.alert.create).toHaveBeenCalledTimes(1);
  });

  // Audit finding 4, end to end: the status that a real telemetry POST writes must be the status the
  // job watches. The old test mocked `"active"` directly, so the route↔job vocabulary mismatch was
  // invisible. This one starts at the route, captures what it persisted, and lets the job read it back.
  it("fires for a device whose status was written by a real telemetry POST", async () => {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    prismaMock.device.findUnique.mockResolvedValue({
      id: "dev-1", childId: "child-1", parentId: undefined, status: "offline",
      child: { id: "child-1", familyId: "fam-1" },
    });
    const updates: Array<Record<string, unknown>> = [];
    prismaMock.device.update.mockImplementation(async ({ data }: { data: Record<string, unknown> }) => {
      updates.push(data);
      return { id: "dev-1", ...data };
    });

    const posted = await app.inject({
      method: "POST",
      url: "/v1/devices/dev-1/telemetry",
      headers: deviceHeader(app),
      payload: { batteryPct: 42 },
    });
    expect(posted.statusCode).toBe(202);
    const written = updates[0];
    expect(written.status).toBe("online");

    // Read back the row the route wrote, honouring the job's `where` exactly as Postgres would: a
    // device is in the result only when its stored status matches the queried status.
    const firstSilence = new Date(NOW.getTime() - 45 * 60_000);
    const row = {
      id: "dev-1", status: written.status as string, lastSeen: firstSilence,
      childId: "child-1", model: "Pixel 7a", child: { familyId: "fam-1", displayName: "Alex" },
    };
    prismaMock.device.findMany.mockImplementation(async ({ where }: { where: { status: string; lastSeen: { lt: Date } } }) =>
      row.status === where.status && row.lastSeen < where.lastSeen.lt ? [row] : [],
    );
    prismaMock.alert.create.mockImplementation(async ({ data }: { data: Record<string, unknown> }) => ({ id: `alert-${prismaMock.alert.create.mock.calls.length}`, ...data }));
    // A real SET NX claim store, not a one-shot stub: the second instance must see the first's claim.
    const claims = new Set<string>();
    const redis = getRedis() as unknown as MockRedis;
    redis.set.mockImplementation(async (key: string, _value: unknown, ...args: unknown[]) => {
      if (!args.includes("NX")) return "OK";
      if (claims.has(key)) return null;
      claims.add(key);
      return "OK";
    });

    const run = await runDeviceSilenceCheck(NOW, { DEVICE_SILENT_MINUTES: "30" } as NodeJS.ProcessEnv);
    expect(prismaMock.device.findMany).toHaveBeenCalledWith(
      expect.objectContaining({ where: { status: written.status, lastSeen: { lt: expect.any(Date) } } }),
    );
    expect(run).toEqual({ checked: 1, alerted: ["dev-1"] });
    expect(prismaMock.alert.create).toHaveBeenCalledWith(
      expect.objectContaining({
        data: expect.objectContaining({
          childId: "child-1", deviceId: "dev-1", severity: "critical", category: "tamper",
          metadata: expect.objectContaining({ type: "device_silent" }),
        }),
      }),
    );
    const firstClaim = `jobs:device-silent:dev-1:${firstSilence.toISOString()}`;
    expect(claims.has(firstClaim)).toBe(true);

    // Same episode, second instance (row still reads online): the claim suppresses a duplicate.
    const duplicate = await runDeviceSilenceCheck(NOW, { DEVICE_SILENT_MINUTES: "30" } as NodeJS.ProcessEnv);
    expect(duplicate.alerted).toEqual([]);
    expect(prismaMock.alert.create).toHaveBeenCalledTimes(1);

    // The watch re-arms: a fresh telemetry POST writes `online` again, time passes, and the next
    // silence episode (new lastSeen) gets its own claim and its own alert.
    const again = await app.inject({
      method: "POST",
      url: "/v1/devices/dev-1/telemetry",
      headers: deviceHeader(app),
      payload: { batteryPct: 41 },
    });
    expect(again.statusCode).toBe(202);
    expect(updates.at(-1)?.status).toBe("online");
    const secondSilence = new Date(NOW.getTime() - 40 * 60_000);
    row.lastSeen = secondSilence;
    row.status = "online";

    const rear = await runDeviceSilenceCheck(NOW, { DEVICE_SILENT_MINUTES: "30" } as NodeJS.ProcessEnv);
    expect(rear).toEqual({ checked: 1, alerted: ["dev-1"] });
    expect(prismaMock.alert.create).toHaveBeenCalledTimes(2);
    expect(claims.has(`jobs:device-silent:dev-1:${secondSilence.toISOString()}`)).toBe(true);
    expect(claims.size).toBe(2);
    await app.close();
  });
});

// Issue #166: at the 5-minute floor the silence window equalled the app's stationary location ping
// (LocationService.kt:430) and was shorter than one telemetry interval (WorkScheduler.kt:48), so a
// healthy phone could be flagged between two reports. The window is now validated against the
// cadence the server mirrors, and the hardware row uses an explicit test-only override.
describe("silence window vs the agent's reporting cadence (issue #166)", () => {
  const read = (relative: string) => readFileSync(new URL(relative, import.meta.url), "utf8");

  it("pins the cadence the server mirrors from the app source", () => {
    const workScheduler = read("../../../apps/child-android/app/src/main/java/com/familyshield/agent/data/WorkScheduler.kt");
    expect(workScheduler).toMatch(/PeriodicWorkRequestBuilder<TelemetryWorker>\(15, TimeUnit\.MINUTES\)/);
    const locationService = read("../../../apps/child-android/app/src/main/java/com/familyshield/agent/services/LocationService.kt");
    expect(locationService).toMatch(/STATIONARY_INTERVAL_MS = 5L \* 60L \* 1000L/);

    expect(TELEMETRY_INTERVAL_MINUTES).toBe(15);
    expect(STATIONARY_PING_INTERVAL_MINUTES).toBe(5);
    // The relationship the issue asks for: two telemetry intervals of headroom, and therefore also
    // more than one stationary ping.
    expect(SILENT_MIN_SAFE_MINUTES).toBe(2 * TELEMETRY_INTERVAL_MINUTES);
    expect(SILENT_MIN_SAFE_MINUTES).toBeGreaterThan(STATIONARY_PING_INTERVAL_MINUTES);
  });

  it("accepts a window with two telemetry intervals of headroom and leaves the default alone", () => {
    expect(resolveSilenceConfig({} as NodeJS.ProcessEnv)).toMatchObject({ minutes: 30, configured: 30, clamped: false, invalid: false });
    expect(silentAfterMinutes({ DEVICE_SILENT_MINUTES: "30" } as NodeJS.ProcessEnv)).toBe(30);
    expect(silentAfterMinutes({ DEVICE_SILENT_MINUTES: "45" } as NodeJS.ProcessEnv)).toBe(45);
    expect(silenceConfigWarning(resolveSilenceConfig({} as NodeJS.ProcessEnv))).toBeNull();
    expect(silenceConfigWarning(resolveSilenceConfig({ DEVICE_SILENT_MINUTES: "45" } as NodeJS.ProcessEnv))).toBeNull();
  });

  it("clamps the tight 5-minute window instead of accepting it", () => {
    const config = resolveSilenceConfig({ DEVICE_SILENT_MINUTES: "5" } as NodeJS.ProcessEnv);
    expect(config).toMatchObject({ minutes: 30, configured: 5, clamped: true, tightOverride: false, invalid: false });
    const warning = silenceConfigWarning(config) ?? "";
    expect(warning).toContain("DEVICE_SILENT_MINUTES=5");
    expect(warning).toContain("15-minute telemetry cadence");
    expect(warning).toContain("clamped to 30");
    expect(silentAfterMinutes({ DEVICE_SILENT_MINUTES: "5" } as NodeJS.ProcessEnv)).toBe(30);
  });

  it("falls back to the default for a value below the old floor or not a number", () => {
    expect(resolveSilenceConfig({ DEVICE_SILENT_MINUTES: "1" } as NodeJS.ProcessEnv)).toMatchObject({ minutes: 30, invalid: true });
    expect(resolveSilenceConfig({ DEVICE_SILENT_MINUTES: "five" } as NodeJS.ProcessEnv)).toMatchObject({ minutes: 30, invalid: true });
    expect(silenceConfigWarning(resolveSilenceConfig({ DEVICE_SILENT_MINUTES: "1" } as NodeJS.ProcessEnv))).toContain("not an integer");
  });

  it("honours the test-only override with a loud warning", () => {
    const config = resolveSilenceConfig({ DEVICE_SILENT_MINUTES: "5", DEVICE_SILENT_ALLOW_TIGHT: "1" } as NodeJS.ProcessEnv);
    expect(config).toMatchObject({ minutes: 5, configured: 5, tightOverride: true, clamped: false });
    const warning = silenceConfigWarning(config) ?? "";
    expect(warning).toContain("TEST ONLY");
    expect(warning).toContain("DEVICE_SILENT_MINUTES=5");
    expect(silentAfterMinutes({ DEVICE_SILENT_MINUTES: "5", DEVICE_SILENT_ALLOW_TIGHT: "1" } as NodeJS.ProcessEnv)).toBe(5);
    // The override cannot go below the historic floor, and does not change a safe value.
    expect(silentAfterMinutes({ DEVICE_SILENT_MINUTES: "1", DEVICE_SILENT_ALLOW_TIGHT: "1" } as NodeJS.ProcessEnv)).toBe(30);
    expect(silentAfterMinutes({ DEVICE_SILENT_MINUTES: "30", DEVICE_SILENT_ALLOW_TIGHT: "1" } as NodeJS.ProcessEnv)).toBe(30);
  });

  it("warns at startup and starts with the effective window, not the configured one", () => {
    const warn = vi.spyOn(console, "warn").mockImplementation(() => {});
    const log = vi.spyOn(console, "log").mockImplementation(() => {});
    try {
      startDeviceSilenceScheduler({ DEVICE_SILENT_MINUTES: "5" } as NodeJS.ProcessEnv);
      expect(warn).toHaveBeenCalledTimes(1);
      expect(String(warn.mock.calls[0]?.[0])).toContain("clamped to 30");
      expect(String(log.mock.calls[0]?.[0])).toContain("after=30m");
    } finally {
      stopDeviceSilenceScheduler();
      warn.mockRestore();
      log.mockRestore();
    }
  });
});
