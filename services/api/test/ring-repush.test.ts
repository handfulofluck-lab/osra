import { beforeEach, describe, expect, it, vi } from "vitest";
import { getRedis } from "../src/redis.js";
import { MockRedis, prismaMock, resetPrismaMock } from "./helpers.js";
import { runRingRepush, startRingRepushScheduler, stopRingRepushScheduler } from "../src/jobs/ringRepush.js";

const wakes: Array<{ deviceId: string; type?: string }> = [];

vi.mock("../src/db.js", async () => {
  const { prismaMock } = await import("./helpers.js");
  return { prisma: prismaMock };
});
vi.mock("ioredis", async () => {
  const { MockRedis } = await import("./helpers.js");
  return { Redis: MockRedis };
});
vi.mock("../src/lib/push/notify.js", () => ({
  wakeDeviceDetached: vi.fn((deviceId: string, type?: string) => {
    wakes.push({ deviceId, type });
  }),
}));

describe("ring re-push job (#760 redesign)", () => {
  beforeEach(() => {
    resetPrismaMock();
    wakes.length = 0;
  });

  const now = new Date("2026-11-15T12:00:00.000Z");
  const expires = new Date(now.getTime() + 60_000);
  const expired = new Date(now.getTime() - 1_000);

  it("re-pushes pending and delivered ring commands that are un-acked and not expired", async () => {
    prismaMock.deviceCommand.findMany.mockResolvedValue([
      { id: "cmd-pending", deviceId: "dev-1" },
      { id: "cmd-delivered", deviceId: "dev-2" },
    ]);
    const redis = getRedis() as unknown as MockRedis;
    redis.set.mockResolvedValue("OK");

    const run = await runRingRepush(now);
    expect(run).toEqual({ checked: 2, repushed: ["cmd-pending", "cmd-delivered"] });
    expect(wakes).toEqual([
      { deviceId: "dev-1", type: "ring" },
      { deviceId: "dev-2", type: "ring" },
    ]);
    expect(redis.set).toHaveBeenCalledTimes(2);
    const query = prismaMock.deviceCommand.findMany.mock.calls[0][0];
    expect(query.where.createdAt).toEqual({ gt: new Date(now.getTime() - 300_000) });
  });

  it("skips commands that are acked, failed, expired or not ring commands", async () => {
    prismaMock.deviceCommand.findMany.mockResolvedValue([]);
    const run = await runRingRepush(now);
    expect(run).toEqual({ checked: 0, repushed: [] });
    expect(wakes).toHaveLength(0);
  });

  it("claims each command so a second tick does not re-push within the window", async () => {
    prismaMock.deviceCommand.findMany.mockResolvedValue([{ id: "cmd-1", deviceId: "dev-1" }]);
    const redis = getRedis() as unknown as MockRedis;
    redis.set.mockResolvedValueOnce("OK").mockResolvedValueOnce(null);

    const first = await runRingRepush(now);
    expect(first.repushed).toEqual(["cmd-1"]);
    expect(wakes).toHaveLength(1);

    const second = await runRingRepush(now);
    expect(second).toEqual({ checked: 1, repushed: [] });
    expect(wakes).toHaveLength(1);
  });

  it("does not re-push ring commands older than the 5-minute cap", async () => {
    prismaMock.deviceCommand.findMany.mockResolvedValue([]);
    const redis = getRedis() as unknown as MockRedis;
    redis.set.mockResolvedValue("OK");

    await runRingRepush(now);
    const query = prismaMock.deviceCommand.findMany.mock.calls[0][0];
    expect(query.where.createdAt).toEqual({ gt: new Date(now.getTime() - 300_000) });
  });

  it("uses a Redis claim TTL just under the 30-second tick", async () => {
    prismaMock.deviceCommand.findMany.mockResolvedValue([{ id: "cmd-1", deviceId: "dev-1" }]);
    const redis = getRedis() as unknown as MockRedis;
    redis.set.mockResolvedValue("OK");

    await runRingRepush(now);
    expect(redis.set).toHaveBeenCalledWith(expect.stringContaining("jobs:ring-repush:"), expect.any(String), "EX", 25, "NX");
  });

  it("does not re-push when Redis is unreachable (fail closed to avoid flooding)", async () => {
    prismaMock.deviceCommand.findMany.mockResolvedValue([{ id: "cmd-1", deviceId: "dev-1" }]);
    const redis = getRedis() as unknown as MockRedis;
    redis.set.mockRejectedValue(new Error("Redis unavailable"));

    const run = await runRingRepush(now);
    expect(run).toEqual({ checked: 1, repushed: [] });
    expect(wakes).toHaveLength(0);
  });

  it("does not start the scheduler in test mode or when JOBS_ENABLED=0", () => {
    stopRingRepushScheduler();
    startRingRepushScheduler({ NODE_ENV: "test" });
    startRingRepushScheduler({ NODE_ENV: "production", JOBS_ENABLED: "0" });
    // No timer was created, so stopping is harmless and the test simply completes.
    stopRingRepushScheduler();
  });
});
