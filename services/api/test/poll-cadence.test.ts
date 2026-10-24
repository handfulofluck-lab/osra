import { readFileSync } from "node:fs";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { prismaMock, resetPrismaMock, buildApp, deviceHeader } from "./helpers.js";

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

import { deviceRoutes } from "../src/routes/devices.js";
import { setPushProviders } from "../src/lib/push/notify.js";
import type { PushProvider } from "../src/lib/push/types.js";
import {
  LAST_SEEN_REFRESH_MS,
  POLL_AFTER_HEADER,
  POLL_FAST_SECONDS,
  POLL_PUSH_SECONDS,
  lastSeenIsStale,
  pollAfterSeconds,
} from "../src/lib/pollCadence.js";
import { SILENT_MIN_SAFE_MINUTES } from "../src/jobs/deviceSilence.js";

/**
 * Issue #353 (roadmap 5.8): the commands poll tells the agent when to poll next. 600 s only when this
 * server can actually wake the device by push; 60 s in every other case, which is what every agent did
 * before. The body stays the array older agents parse.
 */
const fakeProvider = (platform: "android" | "ios"): PushProvider =>
  ({ platform, send: vi.fn(async () => ({ ok: true })) }) as unknown as PushProvider;

const TOKEN = "t".repeat(40);
const fresh = () => new Date(Date.now() - 60_000);
const device = (over: Record<string, unknown> = {}) => ({
  id: "dev-1",
  childId: "child-1",
  platform: "android",
  pushToken: TOKEN,
  lastSeen: fresh(),
  child: { familyId: "fam-1" },
  ...over,
});

async function poll(dev: Record<string, unknown>) {
  const app = await buildApp(deviceRoutes, "/v1/devices");
  prismaMock.device.findUnique.mockResolvedValue(dev);
  prismaMock.$queryRaw.mockResolvedValue([]);
  prismaMock.device.updateMany.mockResolvedValue({ count: 1 });
  const res = await app.inject({ method: "GET", url: "/v1/devices/dev-1/commands?ack=1", headers: deviceHeader(app) });
  await app.close();
  return res;
}

describe("poll cadence header (#353)", () => {
  beforeEach(() => resetPrismaMock());
  afterEach(() => setPushProviders(null));

  it("says 600 when a provider for the device's platform is configured and the device has a token", async () => {
    setPushProviders([fakeProvider("android")]);
    const res = await poll(device());
    expect(res.statusCode).toBe(200);
    expect(res.headers[POLL_AFTER_HEADER.toLowerCase()]).toBe(String(POLL_PUSH_SECONDS));
    expect(res.json()).toEqual([]);
  });

  it("says 60 with no provider configured, even with a token on file", async () => {
    setPushProviders([]);
    const res = await poll(device());
    expect(res.headers[POLL_AFTER_HEADER.toLowerCase()]).toBe(String(POLL_FAST_SECONDS));
  });

  it("says 60 when the device has no token (never registered, or cleared after a dead-token wake)", async () => {
    setPushProviders([fakeProvider("android")]);
    const res = await poll(device({ pushToken: null }));
    expect(res.headers[POLL_AFTER_HEADER.toLowerCase()]).toBe(String(POLL_FAST_SECONDS));
  });

  it("says 60 when only another platform's provider is configured", async () => {
    setPushProviders([fakeProvider("ios")]);
    const res = await poll(device({ platform: "android" }));
    expect(res.headers[POLL_AFTER_HEADER.toLowerCase()]).toBe(String(POLL_FAST_SECONDS));
    // An iOS device rides the Android (FCM) provider when there is no APNs one, as notifyDeviceWake does.
    setPushProviders([fakeProvider("android")]);
    expect(pollAfterSeconds({ id: "d", platform: "ios", pushToken: TOKEN })).toBe(POLL_PUSH_SECONDS);
  });

  it("keeps the body shape: the claimed commands array, unchanged", async () => {
    setPushProviders([fakeProvider("android")]);
    const app = await buildApp(deviceRoutes, "/v1/devices");
    prismaMock.device.findUnique.mockResolvedValue(device());
    prismaMock.device.updateMany.mockResolvedValue({ count: 0 });
    const t0 = new Date("2026-10-24T00:00:00Z");
    const row = { id: "c1", deviceId: "dev-1", type: "lock", payload: {}, status: "delivered", createdAt: t0, expiresAt: t0, attempts: 1 };
    prismaMock.$queryRaw.mockResolvedValue([row]);
    const res = await app.inject({ method: "GET", url: "/v1/devices/dev-1/commands?ack=1", headers: deviceHeader(app) });
    await app.close();
    expect(res.statusCode).toBe(200);
    expect(res.json()).toEqual([{ id: "c1", deviceId: "dev-1", type: "lock", payload: {}, ts: t0.toISOString(), expiresAt: t0.toISOString(), attempt: 1 }]);
  });
});

describe("the poll refreshes a stale lastSeen (#353 part D)", () => {
  beforeEach(() => resetPrismaMock());
  afterEach(() => setPushProviders(null));

  it("writes lastSeen when it is older than the refresh window, with a compare so two polls are one write", async () => {
    setPushProviders([]);
    const before = Date.now();
    await poll(device({ lastSeen: new Date(Date.now() - LAST_SEEN_REFRESH_MS - 30_000) }));
    const after = Date.now();
    expect(prismaMock.device.updateMany).toHaveBeenCalledTimes(1);
    const arg = prismaMock.device.updateMany.mock.calls[0][0];
    expect(arg.where.id).toBe("dev-1");
    // The compare is in the WHERE, so a second poll racing this one matches nothing.
    const cutoff = arg.where.lastSeen.lt.getTime();
    expect(cutoff).toBeGreaterThanOrEqual(before - LAST_SEEN_REFRESH_MS);
    expect(cutoff).toBeLessThanOrEqual(after - LAST_SEEN_REFRESH_MS);
    expect(arg.data).toMatchObject({ status: "online" });
    expect(arg.data.lastSeen).toBeInstanceOf(Date);
  });

  it("does not write when lastSeen is fresh: a poll is a read almost every time", async () => {
    setPushProviders([]);
    await poll(device({ lastSeen: fresh() }));
    expect(prismaMock.device.updateMany).not.toHaveBeenCalled();
  });

  it("a failed refresh never fails the poll: the commands were already claimed", async () => {
    setPushProviders([]);
    const app = await buildApp(deviceRoutes, "/v1/devices");
    prismaMock.device.findUnique.mockResolvedValue(device({ lastSeen: null }));
    prismaMock.$queryRaw.mockResolvedValue([]);
    prismaMock.device.updateMany.mockRejectedValue(new Error("db down"));
    const warn = vi.spyOn(console, "warn").mockImplementation(() => undefined);
    const res = await app.inject({ method: "GET", url: "/v1/devices/dev-1/commands?ack=1", headers: deviceHeader(app) });
    await app.close();
    warn.mockRestore();
    expect(res.statusCode).toBe(200);
    expect(res.headers[POLL_AFTER_HEADER.toLowerCase()]).toBe(String(POLL_FAST_SECONDS));
  });

  it("the window edge: exactly the refresh window old is stale, a second younger is not", () => {
    const now = new Date("2026-10-24T00:00:00Z");
    expect(lastSeenIsStale(new Date(now.getTime() - LAST_SEEN_REFRESH_MS), now)).toBe(true);
    expect(lastSeenIsStale(new Date(now.getTime() - LAST_SEEN_REFRESH_MS + 1000), now)).toBe(false);
    expect(lastSeenIsStale(null, now)).toBe(true);
  });
});

// The agent half of #353 lives in Kotlin. Like device-silence.test.ts, this reads its constants so the
// two sides cannot drift: a renamed header or a clamp that cuts off 600 would silently put every phone
// back on the 60 s poll (or worse, a 30 s one).
describe("the agent honours what this server sends (#353)", () => {
  const kotlin = readFileSync(
    new URL("../../../apps/child-android/app/src/main/java/com/familyshield/agent/services/IdleCadence.kt", import.meta.url),
    "utf8",
  );
  const constMs = (name: string): number => {
    const m = kotlin.match(new RegExp(`const val ${name}: Long = ([0-9L* ]+)`));
    if (!m) throw new Error(`IdleCadence.kt no longer declares ${name}`);
    return m[1].split("*").reduce((acc, part) => acc * Number(part.trim().replace(/L$/, "")), 1);
  };

  it("uses the same header name", () => {
    expect(kotlin).toContain(`const val POLL_AFTER_HEADER: String = "${POLL_AFTER_HEADER}"`);
  });

  it("does not clamp either value the server sends, and defaults to the no-push value", () => {
    expect(constMs("MIN_POLL_MS")).toBeLessThanOrEqual(POLL_FAST_SECONDS * 1000);
    expect(constMs("MAX_POLL_MS")).toBeGreaterThanOrEqual(POLL_PUSH_SECONDS * 1000);
    expect(constMs("DEFAULT_POLL_MS")).toBe(POLL_FAST_SECONDS * 1000);
  });

  it("keeps every idle report well inside the silent-device window", () => {
    // A healthy idle phone reports at least once per poll ceiling and per stationary flush; the
    // silence window (two telemetry intervals) must stay longer than both, or #166 comes back.
    expect(constMs("MAX_POLL_MS")).toBeLessThan(SILENT_MIN_SAFE_MINUTES * 60_000);
    expect(constMs("STATIONARY_FLUSH_AGE_MS")).toBeLessThan(SILENT_MIN_SAFE_MINUTES * 60_000);
    // And a poll refreshes lastSeen whenever it is at least this old, so the push cadence keeps it fresh.
    expect(LAST_SEEN_REFRESH_MS).toBeLessThan(POLL_PUSH_SECONDS * 1000);
  });
});
