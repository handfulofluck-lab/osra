import { beforeEach, describe, expect, it, vi } from "vitest";
import { getRedis } from "../src/redis.js";
import { isSilent, runDeviceSilenceCheck, silentAfterMinutes } from "../src/jobs/deviceSilence.js";
import { MockRedis, prismaMock, resetPrismaMock } from "./helpers.js";

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

  it("pure rule: active + unseen for longer than the window", () => {
    expect(isSilent("active", new Date(NOW.getTime() - 31 * 60_000), NOW, 30)).toBe(true);
    expect(isSilent("active", new Date(NOW.getTime() - 29 * 60_000), NOW, 30)).toBe(false);
    expect(isSilent("offline", new Date(NOW.getTime() - 3 * 3600_000), NOW, 30)).toBe(false);
    expect(silentAfterMinutes({ DEVICE_SILENT_MINUTES: "15" } as NodeJS.ProcessEnv)).toBe(15);
    expect(silentAfterMinutes({ DEVICE_SILENT_MINUTES: "1" } as NodeJS.ProcessEnv)).toBe(30);
    expect(silentAfterMinutes({} as NodeJS.ProcessEnv)).toBe(30);
  });

  it("raises one critical tamper/device_silent alert per episode and flips the device to offline", async () => {
    const lastSeen = new Date(NOW.getTime() - 45 * 60_000);
    prismaMock.device.findMany.mockResolvedValue([
      { id: "dev-1", status: "active", lastSeen, childId: "child-1", model: "SM-F721B", child: { familyId: "fam-1", displayName: "Alex" } },
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
});
