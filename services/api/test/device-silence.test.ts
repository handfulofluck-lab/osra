import { beforeEach, describe, expect, it, vi } from "vitest";
import { getRedis } from "../src/redis.js";
import { isSilent, runDeviceSilenceCheck, silentAfterMinutes } from "../src/jobs/deviceSilence.js";
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
    expect(silentAfterMinutes({ DEVICE_SILENT_MINUTES: "15" } as NodeJS.ProcessEnv)).toBe(15);
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
