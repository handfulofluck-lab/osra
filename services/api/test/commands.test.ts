import { beforeEach, describe, expect, it, vi } from "vitest";
import { readFileSync } from "node:fs";
import { prismaMock, resetPrismaMock, buildApp, authHeader, deviceHeader } from "./helpers.js";

vi.mock("../src/db.js", () => ({ prisma: prismaMock }));
vi.mock("../src/redis.js", async () => {
  const { MockRedis } = await import("./helpers.js");
  const redis = new MockRedis();
  return {
    getRedis: () => redis,
    publishJson: vi.fn(async () => undefined),
    setJson: vi.fn(async () => undefined),
    getJson: vi.fn(async () => null),
    setJsonNx: vi.fn(async () => true),
  };
});

import {
  ackDeviceCommand,
  claimPendingCommands,
  enqueueDeviceCommand,
  listDeviceCommands,
  ttlFor,
  MAX_ATTEMPTS,
  REDELIVER_AFTER_SECONDS,
} from "../src/lib/deviceCommands.js";
import { deviceRoutes } from "../src/routes/devices.js";
import { publishJson } from "../src/redis.js";

const DEVICE = { id: "dev-1", childId: "child-1", child: { familyId: "fam-1" } };

describe("durable command queue (Phase 2b)", () => {
  beforeEach(() => resetPrismaMock());

  it("persists a row with a type-specific TTL and wakes the device over pub/sub", async () => {
    const before = Date.now();
    const msg = await enqueueDeviceCommand("dev-1", "ring", {}, { requestedBy: "parent-1" });
    const created = prismaMock.deviceCommand.create.mock.calls[0][0].data;
    expect(created).toMatchObject({ deviceId: "dev-1", type: "ring", requestedBy: "parent-1" });
    const ttlMs = created.expiresAt.getTime() - before;
    expect(ttlMs).toBeGreaterThan(ttlFor("ring") * 1000 - 2000);
    expect(ttlMs).toBeLessThanOrEqual(ttlFor("ring") * 1000 + 50);
    expect(ttlFor("ring")).toBe(600);
    expect(ttlFor("lock")).toBe(86400);
    expect(ttlFor("consent_revoked")).toBe(7 * 86400);
    expect(msg).toMatchObject({ deviceId: "dev-1", type: "ring", payload: {}, attempt: 0 });
    expect(publishJson).toHaveBeenCalledWith("device:dev-1:commands", expect.objectContaining({ id: msg.id, type: "ring" }));
  });

  it("coalesces rules_updated onto an existing pending row instead of stacking duplicates", async () => {
    const existing = { id: "c-old", deviceId: "dev-1", type: "rules_updated", payload: { reason: "x" }, status: "pending", createdAt: new Date(), expiresAt: new Date(Date.now() + 1000), attempts: 0 };
    prismaMock.deviceCommand.findFirst.mockResolvedValueOnce(existing);
    const msg = await enqueueDeviceCommand("dev-1", "rules_updated", { reason: "y" });
    expect(msg.id).toBe("c-old");
    expect(prismaMock.deviceCommand.create).not.toHaveBeenCalled();
    // Other types never coalesce: two bonus grants are two commands.
    await enqueueDeviceCommand("dev-1", "bonus_time", { minutes: 10 });
    await enqueueDeviceCommand("dev-1", "bonus_time", { minutes: 10 });
    expect(prismaMock.deviceCommand.create).toHaveBeenCalledTimes(2);
  });

  it("claims with one UPDATE…RETURNING, sweeps expired first, and only re-offers to ack-capable agents", async () => {
    prismaMock.$queryRaw.mockResolvedValue([]);
    await claimPendingCommands("dev-1");
    const [sweep] = prismaMock.$executeRaw.mock.calls[0];
    expect(sweep.join("?")).toContain("'expired'");
    const [plain] = prismaMock.$queryRaw.mock.calls[0];
    expect(plain.join("?")).toContain("\"status\" = 'pending'");
    expect(plain.join("?")).not.toContain("ackedAt");

    prismaMock.$queryRaw.mockClear();
    await claimPendingCommands("dev-1", { ackCapable: true });
    const [redeliver, ...params] = prismaMock.$queryRaw.mock.calls[0];
    const sql = redeliver.join("?");
    expect(sql).toContain("\"ackedAt\" IS NULL");
    expect(sql).toContain("\"attempts\" <");
    expect(params).toContain(MAX_ATTEMPTS);
    const dates = params.filter((p: unknown) => p instanceof Date) as Date[];
    const cutoff = new Date(Math.min(...dates.map((d) => d.getTime())));
    const bound = new Date(Math.max(...dates.map((d) => d.getTime())));
    expect(Date.now() - bound.getTime()).toBeLessThan(5000); // "now" is bound from JS, not the server
    expect(bound.getTime() - cutoff.getTime()).toBe(REDELIVER_AFTER_SECONDS * 1000);
  });

  it("never uses the server's NOW() — the instant is bound from JS (issue #53, non-UTC databases)", async () => {
    prismaMock.$queryRaw.mockResolvedValue([]);
    await claimPendingCommands("dev-1", { ackCapable: true });
    const sweepSql = prismaMock.$executeRaw.mock.calls[0][0].join("?");
    const claimSql = prismaMock.$queryRaw.mock.calls[0][0].join("?");
    const sqlNow = /(?<!Date\.)\bnow\(\)/i; // SQL NOW(), not JavaScript Date.now()
    expect(sweepSql).not.toMatch(sqlNow);
    expect(claimSql).not.toMatch(sqlNow);
    const sweepParams = prismaMock.$executeRaw.mock.calls[0].slice(1);
    const claimParams = prismaMock.$queryRaw.mock.calls[0].slice(1);
    expect(sweepParams.some((p: unknown) => p instanceof Date)).toBe(true);
    expect(claimParams.filter((p: unknown) => p instanceof Date).length).toBeGreaterThanOrEqual(2);
    // Guard against the regression at the source level too: no NOW() anywhere in the queue module.
    const src = readFileSync(new URL("../src/lib/deviceCommands.ts", import.meta.url), "utf8")
      .replace(/\/\*[\s\S]*?\*\//g, "")
      .replace(/^\s*\/\/.*$/gm, "");
    expect(src).not.toMatch(sqlNow);
  });

  it("returns claimed rows oldest first in the agent wire shape", async () => {
    const t0 = new Date("2026-10-16T10:00:00Z");
    const t1 = new Date("2026-10-16T10:01:00Z");
    prismaMock.$queryRaw.mockResolvedValue([
      { id: "b", deviceId: "dev-1", type: "ring", payload: {}, status: "delivered", createdAt: t1, expiresAt: t1, attempts: 1 },
      { id: "a", deviceId: "dev-1", type: "lock", payload: { reason: "bedtime" }, status: "delivered", createdAt: t0, expiresAt: t0, attempts: 2 },
    ]);
    const out = await claimPendingCommands("dev-1");
    expect(out.map((c) => c.id)).toEqual(["a", "b"]);
    expect(out[0]).toEqual({ id: "a", deviceId: "dev-1", type: "lock", payload: { reason: "bedtime" }, ts: t0.toISOString(), expiresAt: t0.toISOString(), attempt: 2 });
  });

  it("acks only a delivered row of that device; ok→acked, failed→failed, unknown→null", async () => {
    prismaMock.deviceCommand.updateMany.mockResolvedValueOnce({ count: 1 });
    prismaMock.deviceCommand.findUnique.mockResolvedValueOnce({ id: "c1", status: "acked" });
    expect(await ackDeviceCommand("dev-1", "c1", "ok", { lockedAt: "now" })).toEqual({ id: "c1", status: "acked" });
    expect(prismaMock.deviceCommand.updateMany).toHaveBeenCalledWith(
      expect.objectContaining({ where: { id: "c1", deviceId: "dev-1", status: "delivered" }, data: expect.objectContaining({ status: "acked", result: { lockedAt: "now" } }) }),
    );
    prismaMock.deviceCommand.updateMany.mockResolvedValueOnce({ count: 1 });
    prismaMock.deviceCommand.findUnique.mockResolvedValueOnce({ id: "c2", status: "failed" });
    expect(await ackDeviceCommand("dev-1", "c2", "failed")).toEqual({ id: "c2", status: "failed" });
    prismaMock.deviceCommand.updateMany.mockResolvedValueOnce({ count: 0 });
    expect(await ackDeviceCommand("dev-1", "nope", "ok")).toBeNull();
  });

  it("history reports an unswept pending-but-expired row as expired", async () => {
    prismaMock.deviceCommand.findMany.mockResolvedValue([
      { id: "x", status: "pending", expiresAt: new Date(Date.now() - 1000), createdAt: new Date() },
      { id: "y", status: "pending", expiresAt: new Date(Date.now() + 100000), createdAt: new Date() },
      { id: "z", status: "acked", expiresAt: new Date(Date.now() - 1000), createdAt: new Date() },
    ]);
    const items = await listDeviceCommands("dev-1", 500);
    expect(items.map((i) => i.status)).toEqual(["expired", "pending", "acked"]);
    expect(prismaMock.deviceCommand.findMany).toHaveBeenCalledWith(expect.objectContaining({ take: 100 }));
  });
});

describe("locate_now against the device's last-reported location grant (issue #221 D1)", () => {
  beforeEach(() => {
    resetPrismaMock();
    vi.mocked(publishJson).mockClear();
  });

  async function postLocate(device: Record<string, unknown>) {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    prismaMock.device.findUnique.mockResolvedValue(device);
    const res = await app.inject({
      method: "POST",
      url: "/v1/devices/dev-1/command",
      headers: authHeader(app),
      payload: { command: "locate_now" },
    });
    await app.close();
    return res;
  }

  it("fails at the POST with background_location_missing when the last report is while-in-use only", async () => {
    const res = await postLocate({ ...DEVICE, locationGrant: "while_in_use", locationGrantReportedAt: new Date() });
    expect(res.statusCode).toBe(200);
    expect(res.json()).toMatchObject({ published: false, status: "failed", reason: "background_location_missing", type: "locate_now" });
    // The row is born failed, with the reason in `result` (what /commands/history returns), so it
    // can never be claimed by a WorkManager tick that would run 15 minutes later.
    expect(prismaMock.deviceCommand.create).toHaveBeenCalledTimes(1);
    expect(prismaMock.deviceCommand.create.mock.calls[0][0].data).toMatchObject({
      deviceId: "dev-1",
      type: "locate_now",
      status: "failed",
      result: { reason: "background_location_missing" },
      requestedBy: "parent-1",
    });
    // No device round trip: nothing is woken over pub/sub.
    expect(publishJson).not.toHaveBeenCalled();
  });

  it("fails at the POST with location_permission_missing when the last report is no location at all", async () => {
    const res = await postLocate({ ...DEVICE, locationGrant: "none", locationGrantReportedAt: new Date() });
    expect(res.statusCode).toBe(200);
    expect(res.json()).toMatchObject({ published: false, status: "failed", reason: "location_permission_missing" });
    expect(prismaMock.deviceCommand.create.mock.calls[0][0].data).toMatchObject({
      status: "failed",
      result: { reason: "location_permission_missing" },
    });
    expect(publishJson).not.toHaveBeenCalled();
  });

  it("queues normally when the last report has the background grant", async () => {
    const res = await postLocate({ ...DEVICE, locationGrant: "background", locationGrantReportedAt: new Date() });
    expect(res.statusCode).toBe(200);
    expect(res.json()).toMatchObject({ published: true, status: "pending", type: "locate_now" });
    const data = prismaMock.deviceCommand.create.mock.calls[0][0].data;
    expect(data).toMatchObject({ deviceId: "dev-1", type: "locate_now" });
    expect(data).not.toHaveProperty("status");
    expect(publishJson).toHaveBeenCalledWith("device:dev-1:commands", expect.objectContaining({ type: "locate_now" }));
  });

  it("queues when the stored grant is stale, so the phone answers instead of the server guessing (Claude's Flip4 finding)", async () => {
    // "Allow all the time" was granted on the phone and a Locate four seconds later was still
    // refused, because the server only knew the grant from the previous 15-minute upload. A report
    // older than one telemetry period is not evidence about the phone now.
    const twoHoursAgo = new Date(Date.now() - 2 * 60 * 60 * 1000);
    const res = await postLocate({ ...DEVICE, locationGrant: "while_in_use", locationGrantReportedAt: twoHoursAgo });
    expect(res.statusCode).toBe(200);
    expect(res.json()).toMatchObject({ published: true, status: "pending", type: "locate_now" });
    expect(publishJson).toHaveBeenCalled();
  });

  it("queues when the grant has no report date at all", async () => {
    const res = await postLocate({ ...DEVICE, locationGrant: "while_in_use", locationGrantReportedAt: null });
    expect(res.statusCode).toBe(200);
    expect(res.json()).toMatchObject({ published: true, status: "pending" });
    expect(publishJson).toHaveBeenCalled();
  });

  it("still refuses on a report younger than one telemetry period", async () => {
    const nineteenMinutesAgo = new Date(Date.now() - 19 * 60 * 1000);
    const res = await postLocate({ ...DEVICE, locationGrant: "none", locationGrantReportedAt: nineteenMinutesAgo });
    expect(res.statusCode).toBe(200);
    expect(res.json()).toMatchObject({ published: false, status: "failed", reason: "location_permission_missing" });
  });

  it("queues normally when the device has never reported a grant (older agent or no telemetry yet)", async () => {
    const res = await postLocate({ ...DEVICE, locationGrant: null });
    expect(res.statusCode).toBe(200);
    expect(res.json()).toMatchObject({ published: true, status: "pending" });
    expect(publishJson).toHaveBeenCalled();
  });

  it("leaves every other command type alone even when the background grant is missing", async () => {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    prismaMock.device.findUnique.mockResolvedValue({ ...DEVICE, locationGrant: "while_in_use" });
    const ring = await app.inject({ method: "POST", url: "/v1/devices/dev-1/command", headers: authHeader(app), payload: { command: "ring" } });
    expect(ring.statusCode).toBe(200);
    expect(ring.json()).toMatchObject({ published: true, status: "pending", type: "ring" });
    await app.close();
  });

  it("keeps locate_now claimable for 20 minutes — the 15-minute WorkManager floor plus its 5-minute flex", async () => {
    expect(ttlFor("locate_now")).toBe(20 * 60);
    // No other type in the table moved with it.
    expect(ttlFor("ring")).toBe(600);
    expect(ttlFor("stop_ring")).toBe(600);

    const before = Date.now();
    await enqueueDeviceCommand("dev-1", "locate_now", {});
    const created = prismaMock.deviceCommand.create.mock.calls[0][0].data;
    const ttlMs = created.expiresAt.getTime() - before;
    expect(ttlMs).toBeGreaterThan(20 * 60 * 1000 - 2000);
    expect(ttlMs).toBeLessThanOrEqual(20 * 60 * 1000 + 50);
  });
});

describe("command routes (Phase 2b)", () => {
  beforeEach(() => resetPrismaMock());

  it("device acks its delivered command; parents and other devices cannot", async () => {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    prismaMock.device.findUnique.mockResolvedValue(DEVICE);
    prismaMock.deviceCommand.updateMany.mockResolvedValue({ count: 1 });
    prismaMock.deviceCommand.findUnique.mockResolvedValue({ id: "c1", status: "acked" });

    const ok = await app.inject({ method: "POST", url: "/v1/devices/dev-1/commands/c1/ack", headers: deviceHeader(app), payload: { status: "ok", detail: { tookMs: 40 } } });
    expect(ok.statusCode).toBe(200);
    expect(ok.json()).toEqual({ command: { id: "c1", status: "acked" } });

    const parent = await app.inject({ method: "POST", url: "/v1/devices/dev-1/commands/c1/ack", headers: authHeader(app), payload: { status: "ok" } });
    expect(parent.statusCode).toBe(403);
    const other = await app.inject({ method: "POST", url: "/v1/devices/dev-1/commands/c1/ack", headers: deviceHeader(app, { deviceId: "dev-2", childId: "child-1", familyId: "fam-1" }), payload: { status: "ok" } });
    expect(other.statusCode).toBe(403);

    prismaMock.deviceCommand.updateMany.mockResolvedValue({ count: 0 });
    const gone = await app.inject({ method: "POST", url: "/v1/devices/dev-1/commands/c9/ack", headers: deviceHeader(app), payload: { status: "failed" } });
    expect(gone.statusCode).toBe(404);
    const bad = await app.inject({ method: "POST", url: "/v1/devices/dev-1/commands/c1/ack", headers: deviceHeader(app), payload: { status: "maybe" } });
    expect(bad.statusCode).toBe(400);
    await app.close();
  });

  it("parents read history (family-scoped, non-destructive) and ack-capable agents pass ?ack=1", async () => {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    prismaMock.device.findUnique.mockResolvedValue(DEVICE);
    prismaMock.deviceCommand.findMany.mockResolvedValue([{ id: "c1", type: "lock", status: "delivered", expiresAt: new Date(Date.now() + 1000), createdAt: new Date() }]);

    const hist = await app.inject({ method: "GET", url: "/v1/devices/dev-1/commands/history?limit=5", headers: authHeader(app) });
    expect(hist.statusCode).toBe(200);
    expect(hist.json().items[0]).toMatchObject({ id: "c1", status: "delivered" });
    expect(prismaMock.deviceCommand.findMany).toHaveBeenCalledWith(expect.objectContaining({ where: { deviceId: "dev-1" }, take: 5 }));
    expect(prismaMock.$queryRaw).not.toHaveBeenCalled();

    const foreign = await app.inject({ method: "GET", url: "/v1/devices/dev-1/commands/history", headers: authHeader(app, "fam-2") });
    expect(foreign.statusCode).toBe(403);

    prismaMock.$queryRaw.mockResolvedValue([]);
    const drain = await app.inject({ method: "GET", url: "/v1/devices/dev-1/commands?ack=1", headers: deviceHeader(app) });
    expect(drain.statusCode).toBe(200);
    expect(prismaMock.$queryRaw.mock.calls[0][0].join("?")).toContain("\"ackedAt\" IS NULL");
    await app.close();
  });
});
