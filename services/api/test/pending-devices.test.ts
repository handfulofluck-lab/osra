import { beforeEach, describe, expect, it, vi } from "vitest";
import { deviceRoutes } from "../src/routes/devices.js";
import {
  PENDING_DEVICE_MINUTES,
  runPendingDeviceSweep,
  startPendingDeviceScheduler,
  stopPendingDeviceScheduler,
} from "../src/jobs/pendingDevices.js";
import { getRedis } from "../src/redis.js";
import { requestAccepted } from "../src/middleware/pairedAt.js";
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
 * Issue #790 (R2): a device created by an approved pairing claim is PENDING (`Device.pairedAt` null)
 * until one request from it is accepted, and a pending device that never gets there is deleted.
 *
 * The pairing half — what the poll writes, and what the parent's list and envelope exclude — is in
 * `pairing.test.ts`, on the same harness. This file is the two halves that rule crosses: the global
 * `onResponse` hook (`middleware/pairedAt.ts`) and the sweep (`jobs/pendingDevices.ts`), each mounted
 * the way `server.ts` mounts it rather than through a copy.
 *
 * Mutants each row would catch, stated because a test that cannot fail is worse than none (AGENTS.md §3):
 *  - move the pairedAt write into `requireFamily` instead of the response hook → the 403 wrong-device
 *    row goes green (a refused request would clear pending);
 *  - drop `pairedAt: null` from the hook's WHERE → the "never rewritten" row fails;
 *  - drop `pairedAt: null` from the sweep's query → the paired-device row fails;
 *  - drop the `pairedAt: null` guard from the DELETE → the "paired while the sweep ran" row fails;
 *  - call `raiseAlert` from the sweep → the "nothing to the parent" row fails.
 */

const NOW = new Date("2026-11-17T12:00:00.000Z");
const MINUTE = 60_000;

/** The row the routes and the hook both see; `pairedAt` is what the hook may set. */
interface DeviceRow {
  id: string;
  childId: string;
  model: string;
  pairedAt: Date | null;
  child: { familyId: string };
}

function row(overrides: Partial<DeviceRow> = {}): DeviceRow {
  return { id: "dev-1", childId: "child-1", model: "Pixel 7a", pairedAt: null, child: { familyId: "fam-1" }, ...overrides };
}

/** Prisma's behaviour for the hook's statement: it matches the row only while pairedAt is still null. */
function wireStatefulUpdate(devices: DeviceRow[]) {
  prismaMock.device.updateMany.mockImplementation(
    async ({ where, data }: { where: { id: string; pairedAt?: null }; data: { pairedAt?: Date } }) => {
      const target = devices.find((d) => d.id === where.id);
      if (!target) return { count: 0 };
      if (where.pairedAt === null && target.pairedAt !== null) return { count: 0 };
      if (data.pairedAt !== undefined) target.pairedAt = data.pairedAt;
      return { count: 1 };
    },
  );
}

async function deviceApp() {
  return buildApp(deviceRoutes, "/v1/devices", { sessionGuard: true, pairedAtHook: true });
}

describe("what counts as an accepted request (#790)", () => {
  it("2xx and 3xx were acted on; every refusal was not", () => {
    // The boundary the whole fix rests on. Mutant: `statusCode < 500` — a 403 or a 428 would then clear
    // pending, which is exactly the reported bug with a shorter window.
    for (const status of [200, 201, 202, 204, 302]) expect(requestAccepted(status)).toBe(true);
    for (const status of [400, 401, 403, 404, 409, 410, 428, 500, 503]) expect(requestAccepted(status)).toBe(false);
  });
});

describe("a device request that is ACTED ON clears pending (#790)", () => {
  beforeEach(() => resetPrismaMock());

  it("the first accepted request sets pairedAt, and a repeated one does not rewrite it", async () => {
    const devices = [row()];
    prismaMock.device.findUnique.mockImplementation(async ({ where }: { where: { id: string } }) => devices.find((d) => d.id === where.id) ?? null);
    wireStatefulUpdate(devices);
    const app = await deviceApp();

    const first = await app.inject({ method: "GET", url: "/v1/devices/dev-1", headers: deviceHeader(app) });
    expect(first.statusCode).toBe(200);
    expect(prismaMock.device.updateMany).toHaveBeenCalledTimes(1);
    // The WHERE is the idempotency: the row is only written while it is still pending, so a paired
    // device's timestamp is never moved forward by its next poll.
    expect(prismaMock.device.updateMany.mock.calls[0]?.[0]?.where).toEqual({ id: "dev-1", pairedAt: null });
    expect(prismaMock.device.updateMany.mock.calls[0]?.[0]?.data?.pairedAt).toBeInstanceOf(Date);
    const provenAt = devices[0]!.pairedAt;
    expect(provenAt).toBeInstanceOf(Date);

    // A later accepted request (the agent's heartbeat, seconds or minutes later) leaves it alone.
    await new Promise((resolve) => setTimeout(resolve, 5));
    const second = await app.inject({ method: "GET", url: "/v1/devices/dev-1", headers: deviceHeader(app) });
    expect(second.statusCode).toBe(200);
    expect(prismaMock.device.updateMany).toHaveBeenCalledTimes(2);
    expect(prismaMock.device.updateMany.mock.calls[1]?.[0]?.where).toEqual({ id: "dev-1", pairedAt: null });
    expect(devices[0]!.pairedAt).toBe(provenAt);
    await app.close();
  });

  it("a wrong-device 403 leaves it pending", async () => {
    // The refusal the issue names: dev-1's token addressed to dev-2. `requireFamily` resolves dev-2 in
    // the same family, `requireOwnDevice` then refuses — a request that authenticated and did nothing.
    const devices = [row(), row({ id: "dev-2" })];
    prismaMock.device.findUnique.mockImplementation(async ({ where }: { where: { id: string } }) => devices.find((d) => d.id === where.id) ?? null);
    wireStatefulUpdate(devices);
    const app = await deviceApp();

    const res = await app.inject({
      method: "POST",
      url: "/v1/devices/dev-2/telemetry",
      headers: deviceHeader(app),
      payload: { batteryPct: 50 },
    });
    expect(res.statusCode).toBe(403);
    expect(res.json()).toEqual({ error: "forbidden" });
    expect(prismaMock.device.updateMany).not.toHaveBeenCalled();
    expect(devices.every((d) => d.pairedAt === null)).toBe(true);
    await app.close();
  });

  it("a device_revoked 401 leaves it pending", async () => {
    // The gate's own refusal: no row at all is what "revoked" means (ADR-0032), and a tombstone-or-row
    // miss must not be a way to make a row visible.
    prismaMock.device.findUnique.mockResolvedValue(null);
    const app = await deviceApp();

    const res = await app.inject({ method: "GET", url: "/v1/devices/dev-1", headers: deviceHeader(app) });
    expect(res.statusCode).toBe(401);
    expect(res.json()).toEqual({ error: "device_revoked" });
    expect(prismaMock.device.updateMany).not.toHaveBeenCalled();
    await app.close();
  });

  it("a body the route refuses (400) leaves it pending", async () => {
    // A route-level refusal after every auth gate: the device proved its token and the request was still
    // not acted on, so it is not a proof of anything the parent should see.
    const devices = [row()];
    prismaMock.device.findUnique.mockImplementation(async ({ where }: { where: { id: string } }) => devices.find((d) => d.id === where.id) ?? null);
    wireStatefulUpdate(devices);
    const app = await deviceApp();

    const res = await app.inject({ method: "POST", url: "/v1/devices/dev-1/telemetry", headers: deviceHeader(app), payload: { batteryPct: "full" } });
    expect(res.statusCode).toBe(400);
    expect(prismaMock.device.updateMany).not.toHaveBeenCalled();
    await app.close();
  });

  it("a parent's accepted request touches no device's pairedAt", async () => {
    const devices = [row()];
    prismaMock.device.findMany.mockResolvedValue([devices[0]]);
    wireStatefulUpdate(devices);
    const app = await deviceApp();

    const res = await app.inject({ method: "GET", url: "/v1/devices", headers: authHeader(app) });
    expect(res.statusCode).toBe(200);
    expect(prismaMock.device.updateMany).not.toHaveBeenCalled();
    await app.close();
  });

  it("a pending row answers a parent's device reads with 404, and the device's own token still reaches it", async () => {
    // `hidePending` on `requireFamily`: the parent's surface has no such device, and the row's own
    // token is exactly how the row stops being pending. Mutant: apply it to every role → the pending
    // phone can never make the request that proves it (and the second half of this row fails).
    const devices = [row()];
    prismaMock.device.findUnique.mockImplementation(async ({ where }: { where: { id: string } }) => devices.find((d) => d.id === where.id) ?? null);
    wireStatefulUpdate(devices);
    const app = await deviceApp();

    for (const url of ["/v1/devices/dev-1", "/v1/devices/dev-1/commands/history"]) {
      const res = await app.inject({ method: "GET", url, headers: authHeader(app) });
      expect(res.statusCode).toBe(404);
      expect(res.json()).toEqual({ error: "not_found" });
    }
    // A parent's 404 is not a proof: the row is still pending.
    expect(devices[0]!.pairedAt).toBeNull();
    expect(prismaMock.device.updateMany).not.toHaveBeenCalled();

    const own = await app.inject({ method: "GET", url: "/v1/devices/dev-1", headers: deviceHeader(app) });
    expect(own.statusCode).toBe(200);
    expect(devices[0]!.pairedAt).toBeInstanceOf(Date);
    await app.close();
  });
});

describe("pending devices are swept after the window (#790)", () => {
  beforeEach(() => {
    resetPrismaMock();
    prismaMock.device.deleteMany.mockResolvedValue({ count: 1 });
  });

  it("deletes a pending device older than the window and raises nothing to the parent", async () => {
    prismaMock.device.findMany.mockResolvedValue([{ id: "old-1" }]);
    const redis = getRedis() as unknown as MockRedis;

    const run = await runPendingDeviceSweep(NOW, { NODE_ENV: "test" } as NodeJS.ProcessEnv);

    expect(run).toEqual({ checked: 1, deleted: ["old-1"] });
    // One claim per device, so a second instance reads "already claimed" instead of deleting twice.
    expect(redis.set).toHaveBeenCalledWith(`jobs:pending-device:old-1`, NOW.toISOString(), "EX", 600, "NX");
    expect(prismaMock.device.deleteMany).toHaveBeenCalledWith({ where: { id: "old-1", pairedAt: null } });
    // An alert about a phone the parent has never seen would be worse than silence; so would a command.
    expect(prismaMock.alert.create).not.toHaveBeenCalled();
    expect(prismaMock.deviceCommand.create).not.toHaveBeenCalled();
  });

  it("leaves a younger pending device alone: the window is the query's, 30 minutes back from now", async () => {
    // The sweep does not read a row and decide; it asks only for rows past the cutoff. Mutant: a window
    // measured from the wrong clock (createdAt that does not exist, now + 30) → this exact WHERE fails.
    prismaMock.device.findMany.mockResolvedValue([]);

    const run = await runPendingDeviceSweep(NOW, { NODE_ENV: "test" } as NodeJS.ProcessEnv);

    expect(run).toEqual({ checked: 0, deleted: [] });
    expect(prismaMock.device.findMany).toHaveBeenCalledWith({
      where: { pairedAt: null, lastSeen: { lt: new Date(NOW.getTime() - PENDING_DEVICE_MINUTES * MINUTE) } },
      select: { id: true },
    });
    expect(prismaMock.device.deleteMany).not.toHaveBeenCalled();
  });

  it("leaves a paired device alone: only pairedAt IS NULL is ever swept", async () => {
    // Same query, read from the other side: `lastSeen` alone would delete a healthy phone that went
    // quiet (that is `jobs/deviceSilence.ts`'s job, and it alerts; this one must never touch it).
    prismaMock.device.findMany.mockResolvedValue([]);

    await runPendingDeviceSweep(NOW, { NODE_ENV: "test" } as NodeJS.ProcessEnv);

    expect(prismaMock.device.findMany.mock.calls[0]?.[0]?.where).toEqual({
      pairedAt: null,
      lastSeen: { lt: new Date(NOW.getTime() - PENDING_DEVICE_MINUTES * MINUTE) },
    });
    expect(prismaMock.device.deleteMany).not.toHaveBeenCalled();
    expect(prismaMock.alert.create).not.toHaveBeenCalled();
  });

  it("does not delete a device that paired between the query and the delete", async () => {
    // A phone that answers in this window is the family's device: the DELETE repeats the pending
    // predicate instead of trusting the read, so it becomes a zero-row no-op.
    prismaMock.device.findMany.mockResolvedValue([{ id: "late-1" }]);
    prismaMock.device.deleteMany.mockResolvedValue({ count: 0 });

    const run = await runPendingDeviceSweep(NOW, { NODE_ENV: "test" } as NodeJS.ProcessEnv);

    expect(run.deleted).toEqual([]);
    expect(prismaMock.device.deleteMany).toHaveBeenCalledWith({ where: { id: "late-1", pairedAt: null } });
  });

  it("another instance's claim means this one does not delete", async () => {
    prismaMock.device.findMany.mockResolvedValue([{ id: "claimed-1" }]);
    const redis = getRedis() as unknown as MockRedis;
    redis.set.mockResolvedValue(null);

    const run = await runPendingDeviceSweep(NOW, { NODE_ENV: "test" } as NodeJS.ProcessEnv);

    expect(run).toEqual({ checked: 1, deleted: [] });
    expect(prismaMock.device.deleteMany).not.toHaveBeenCalled();
  });

  it("respects JOBS_ENABLED=0 and NODE_ENV=test (no timer started)", () => {
    expect(() => startPendingDeviceScheduler({ JOBS_ENABLED: "0" } as NodeJS.ProcessEnv)).not.toThrow();
    expect(() => startPendingDeviceScheduler({ NODE_ENV: "test" } as NodeJS.ProcessEnv)).not.toThrow();
    stopPendingDeviceScheduler();
  });
});
