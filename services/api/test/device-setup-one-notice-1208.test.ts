import { randomBytes } from "node:crypto";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { PushProvider } from "../src/lib/push/types.js";
import { setPushProviders } from "../src/lib/push/notify.js";
import { signV2 } from "../src/lib/internalAuth.js";
import { incompleteDedupeKey, legacyIncompleteDedupeKey } from "../src/lib/deviceSetup.js";
import { completeDeviceSetupIfReady, evaluateDeviceSetupIncomplete } from "../src/lib/deviceSetupTransitions.js";
import { alertsRoutes } from "../src/routes/alerts.js";
import { buildApp, MockRedis, prismaMock, resetPrismaMock } from "./helpers.js";

vi.mock("../src/db.js", async () => ({ prisma: (await import("./helpers.js")).prismaMock }));
vi.mock("ioredis", async () => ({ Redis: (await import("./helpers.js")).MockRedis }));

// Synthetic only: no real family, child, message or device data.
const CHILD = { id: "child-1", familyId: "fam-1", displayName: "Child One" };
const SECRET = randomBytes(32).toString("hex");
const START = new Date(Date.now() - 31 * 60_000);
const EXPIRY = new Date(START.getTime() + 30 * 60_000);
const SEVEN = {
  accessibility: "granted",
  usage_access: "granted",
  overlay: "granted",
  device_admin: "granted",
  web_filter: "granted",
  location: "granted",
  private_dns: "granted",
} as const;
const FULL_STEPS = [...Object.keys(SEVEN), "notification_listener"] as const;

function caps(grants: Record<string, string>, flavour: "full" | "play" = "full") {
  return { client: { app: "child-android", version: "0.2.0", build: 42, flavour }, grants, features: {} };
}

type Row = Record<string, unknown> & { id: string };

describe("#1208 / osra-security#82: one setup notice per pairing, protection only at the last grant", () => {
  const send = vi.fn(async () => ({ ok: true }));
  const provider: PushProvider = { platform: "android", send };
  let alerts: Row[];
  let deviceRow: Record<string, unknown>;

  const setupNotices = () => alerts.filter((a) =>
    a.dedupeKey === incompleteDedupeKey("dev-1") || a.dedupeKey === legacyIncompleteDedupeKey("dev-1", START));
  const protectedNotices = () => alerts.filter((a) => (a.title as string) === "Phone is protected");
  const transitionDevice = () => ({ ...deviceRow, child: CHILD }) as never;

  // The notice exactly as #1208's TamperAlertWorker serializes it at a79a1748 (TYPE_SETUP_INCOMPLETE):
  // severity warning, category tamper, its title and body, metadata {type, missingGrants}, key setup_incomplete:<id>.
  function phoneNotice() {
    const raw = JSON.stringify({
      childId: CHILD.id,
      deviceId: "dev-1",
      severity: "warning",
      category: "tamper",
      title: "Setup is not finished yet",
      body: "Some required permissions are still missing on this device. Protection will start once setup finishes.",
      metadata: { type: "setup_incomplete_permissions", missingGrants: "notification_listener" },
      dedupeKey: incompleteDedupeKey("dev-1"),
    });
    return { raw, headers: { "content-type": "application/json", ...signV2(SECRET, raw) } };
  }

  beforeEach(() => {
    resetPrismaMock();
    setPushProviders([provider]);
    send.mockClear();
    for (const redis of MockRedis.instances) redis.publish.mockClear();
    alerts = [];
    deviceRow = {
      id: "dev-1",
      childId: CHILD.id,
      platform: "android",
      model: "Test Phone",
      internalSecret: SECRET,
      pairedAt: START,
      setupCompletedAt: null,
      capabilities: caps({ ...SEVEN, notification_listener: "missing" }),
    };
    prismaMock.child.findUnique.mockResolvedValue(CHILD);
    prismaMock.device.findUnique.mockImplementation(async () => ({ ...deviceRow }));
    prismaMock.device.updateMany.mockImplementation(async ({ where, data }) => {
      if (where.id !== deviceRow.id) return { count: 0 };
      if ("setupCompletedAt" in where && where.setupCompletedAt !== deviceRow.setupCompletedAt) return { count: 0 };
      Object.assign(deviceRow, data);
      return { count: 1 };
    });
    prismaMock.digestPrefs.findUnique.mockResolvedValue({ familyId: "fam-1", pushEnabled: true });
    prismaMock.parent.findMany.mockResolvedValue([{ id: "parent-1" }]);
    prismaMock.parentPushToken.findMany.mockResolvedValue([{ id: "token-1", parentId: "parent-1", platform: "android", token: "token" }]);
    // In-memory alert table keyed the way the partial unique index is: one row per dedupe key.
    // The Device row lock read (#1230) sees the committed completion state, not a caller's snapshot.
    prismaMock.$queryRaw.mockImplementation(async (strings: TemplateStringsArray) =>
      Array.from(strings ?? []).join("").includes("FOR NO KEY UPDATE")
        ? [{ setupCompletedAt: deviceRow.setupCompletedAt }]
        : []);
    prismaMock.alert.findFirst.mockImplementation(async ({ where }) =>
      alerts.find((a) =>
        (typeof where.dedupeKey === "object" && where.dedupeKey !== null
          ? (where.dedupeKey.in as string[]).includes(a.dedupeKey as string)
          : a.dedupeKey === where.dedupeKey) &&
        (where.category === undefined || a.category === where.category) &&
        (typeof where.heldDuringSetup !== "boolean" || a.heldDuringSetup === where.heldDuringSetup)) ?? null);
    prismaMock.alert.create.mockImplementation(async ({ data }) => {
      const row = { id: `alert-${alerts.length + 1}`, heldDuringSetup: false, attemptCount: 1, ...data } as Row;
      alerts.push(row);
      return row;
    });
    prismaMock.alert.update.mockImplementation(async ({ where, data }) => {
      const row = alerts.find((a) => a.id === where.id)!;
      Object.assign(row, data);
      return row;
    });
  });

  afterEach(() => {
    setPushProviders(null);
  });

  it("phone notice first, then the 30-minute reminder: one row, one push", async () => {
    const app = await buildApp(alertsRoutes, "/v1/alerts");
    const { raw, headers } = phoneNotice();
    const posted = await app.inject({ method: "POST", url: "/v1/alerts/internal", headers, payload: raw });
    expect(posted.statusCode).toBe(201);
    expect(await evaluateDeviceSetupIncomplete(transitionDevice(), EXPIRY)).toEqual({ due: true, deduplicated: true });
    expect(await evaluateDeviceSetupIncomplete(transitionDevice(), EXPIRY)).toEqual({ due: true, deduplicated: true });
    expect(setupNotices()).toHaveLength(1);
    expect(setupNotices()[0].metadata).toEqual(expect.objectContaining({ serverReminder: true, missing: ["notification_listener"] }));
    expect(prismaMock.alert.update).toHaveBeenCalledTimes(1);
    expect(send).toHaveBeenCalledTimes(1);
    await app.close();
  });

  it("reminder first, then a late phone notice: deduped, still one row and one push", async () => {
    const app = await buildApp(alertsRoutes, "/v1/alerts");
    expect(await evaluateDeviceSetupIncomplete(transitionDevice(), EXPIRY)).toEqual({ due: true, deduplicated: false });
    const { raw, headers } = phoneNotice();
    const posted = await app.inject({ method: "POST", url: "/v1/alerts/internal", headers, payload: raw });
    expect(posted.statusCode).toBe(200);
    expect(setupNotices()).toHaveLength(1);
    expect(send).toHaveBeenCalledTimes(1);
    await app.close();
  });

  it("a fresh Full pairing completes only at the last grant, with a single 'Phone is protected'", async () => {
    const granted: Record<string, string> = Object.fromEntries(FULL_STEPS.map((k) => [k, "missing"]));
    for (const [i, step] of FULL_STEPS.entries()) {
      granted[step] = "granted";
      const now = new Date(START.getTime() + (i + 1) * 1_000);
      const done = await completeDeviceSetupIfReady(transitionDevice(), caps(granted), now);
      expect(done, step).toBe(i === FULL_STEPS.length - 1);
      expect(deviceRow.setupCompletedAt === null, step).toBe(i < FULL_STEPS.length - 1);
    }
    // The phone keeps reporting all-granted afterwards: no second notice.
    expect(await completeDeviceSetupIfReady(transitionDevice(), caps(granted), new Date())).toBe(false);
    expect(protectedNotices()).toHaveLength(1);
    expect(send).toHaveBeenCalledTimes(1);
  });

  it("a Play pairing completes on its seven, without notification access", async () => {
    expect(await completeDeviceSetupIfReady(transitionDevice(), caps({ ...SEVEN, notification_listener: "missing" }, "play"), START))
      .toBe(true);
    expect(protectedNotices()).toHaveLength(1);
  });

  it("no setup notice after completion, and a completed pairing is never re-gated by the new rule", async () => {
    const app = await buildApp(alertsRoutes, "/v1/alerts");
    // Completed before this change, on the old seven; its next Full report still lacks notification access.
    deviceRow.setupCompletedAt = new Date(START.getTime() + 5_000);
    const stillSeven = caps({ ...SEVEN, notification_listener: "missing" });
    expect(await completeDeviceSetupIfReady(transitionDevice(), stillSeven, new Date())).toBe(false);
    expect(deviceRow.setupCompletedAt).not.toBeNull();
    expect(await evaluateDeviceSetupIncomplete({ ...transitionDevice(), capabilities: stillSeven } as never, EXPIRY))
      .toEqual({ due: false, deduplicated: true });

    const { raw, headers } = phoneNotice();
    const posted = await app.inject({ method: "POST", url: "/v1/alerts/internal", headers, payload: raw });
    expect(posted.statusCode).toBe(200);
    expect(posted.json()).toEqual({ dropped: "setup_complete" });
    expect(alerts).toHaveLength(0);
    expect(send).not.toHaveBeenCalled();
    await app.close();
  });
function seedLegacyReminder(missing: string[]) {
    alerts.push({
      id: "legacy-1",
      childId: CHILD.id,
      deviceId: "dev-1",
      severity: "warning",
      category: "tamper",
      title: "Phone setup needs attention",
      heldDuringSetup: false,
      attemptCount: 1,
      dedupeKey: legacyIncompleteDedupeKey("dev-1", START),
      metadata: { type: "setup_incomplete", missing, pairedAt: START.toISOString() },
    });
  }

  it("upgrade, server first: a pre-#1208 reminder stays the one notice, no second row, no push", async () => {
    seedLegacyReminder(["notification_listener"]);
    expect(await evaluateDeviceSetupIncomplete(transitionDevice(), EXPIRY)).toEqual({ due: true, deduplicated: true });
    expect(setupNotices()).toHaveLength(1);
    expect(setupNotices()[0].id).toBe("legacy-1");
    expect(prismaMock.alert.create).not.toHaveBeenCalled();
    expect(send).not.toHaveBeenCalled();
  });

  it("upgrade, phone first: the phone notice dedupes onto the pre-#1208 reminder, then the check adds nothing", async () => {
    seedLegacyReminder(["notification_listener"]);
    const app = await buildApp(alertsRoutes, "/v1/alerts");
    const { raw, headers } = phoneNotice();
    const posted = await app.inject({ method: "POST", url: "/v1/alerts/internal", headers, payload: raw });
    expect(posted.statusCode).toBe(200);
    expect(await evaluateDeviceSetupIncomplete(transitionDevice(), EXPIRY)).toEqual({ due: true, deduplicated: true });
    expect(setupNotices()).toHaveLength(1);
    expect(prismaMock.alert.create).not.toHaveBeenCalled();
    expect(send).not.toHaveBeenCalled();
    await app.close();
  });

  it("a check holding a pre-completion snapshot writes nothing once completion has committed", async () => {
    const stale = transitionDevice(); // read by the scheduler before completion
    const done = await completeDeviceSetupIfReady(transitionDevice(), caps(Object.fromEntries(FULL_STEPS.map((k) => [k, "granted"]))), EXPIRY);
    expect(done).toBe(true);
    expect(await evaluateDeviceSetupIncomplete(stale, EXPIRY)).toEqual({ due: false, deduplicated: true });
    expect(setupNotices()).toHaveLength(0);
    expect(protectedNotices()).toHaveLength(1);
    expect(send).toHaveBeenCalledTimes(1);
  });

  it("a phone notice authenticated before completion committed is still dropped", async () => {
    const app = await buildApp(alertsRoutes, "/v1/alerts");
    const staleDevice = { ...deviceRow }; // what the request loaded at authentication
    prismaMock.device.findUnique.mockImplementation(async () => ({ ...staleDevice }));
    await completeDeviceSetupIfReady(transitionDevice(), caps(Object.fromEntries(FULL_STEPS.map((k) => [k, "granted"]))), new Date());
    const { raw, headers } = phoneNotice();
    const posted = await app.inject({ method: "POST", url: "/v1/alerts/internal", headers, payload: raw });
    expect(posted.statusCode).toBe(200);
    expect(posted.json()).toEqual({ dropped: "setup_complete" });
    expect(setupNotices()).toHaveLength(0);
    expect(send).toHaveBeenCalledTimes(1); // the completion push only
    await app.close();
  });
});
