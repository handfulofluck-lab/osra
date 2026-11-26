import { execFile } from "node:child_process";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import { afterAll, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";

/**
 * osra-security#87 / #1230: setup completion and the #1208 setup notice, ordered by the Device row lock on a
 * real Postgres. Runs on the loopback, trust-only osra_test_* database CI provides (OSRA_TEST_DATABASE_URL), in
 * its own schema so it never touches the tables other database tests rebuild. Synthetic rows only.
 */
const execFileAsync = promisify(execFile);
const databaseUrl = process.env.OSRA_TEST_DATABASE_URL;
const SCHEMA = "setup_order_1230";
if (process.env.OSRA_REQUIRE_DATABASE_TESTS === "1" && !databaseUrl) {
  throw new Error("OSRA_TEST_DATABASE_URL is required when OSRA_REQUIRE_DATABASE_TESTS=1");
}
const target = databaseUrl ? new URL(databaseUrl) : undefined;
if (target && (!["127.0.0.1", "localhost", "::1"].includes(target.hostname) ||
    !/^\/osra_test_[a-z0-9_]+$/.test(target.pathname) || target.password)) {
  throw new Error("The setup ordering tests require a dedicated, trust-only osra_test_* database on loopback");
}
const schemaUrl = target ? (() => { const u = new URL(target.toString()); u.searchParams.set("schema", SCHEMA); return u.toString(); })() : "";

const sent = vi.hoisted(() => ({ events: [] as string[] }));
vi.mock("../src/db.js", async () => {
  const { PrismaClient } = await import("@prisma/client");
  const raw = process.env.OSRA_TEST_DATABASE_URL;
  let url = "postgresql://postgres@127.0.0.1:5432/osra_test_unused";
  if (raw) {
    const u = new URL(raw);
    u.searchParams.set("schema", "setup_order_1230");
    url = u.toString();
  }
  return { prisma: new PrismaClient({ datasources: { db: { url } } }) };
});
vi.mock("../src/realtime/gateway.js", () => ({
  publishFamilyEvent: vi.fn(async () => { sent.events.push("publish"); }),
}));
vi.mock("../src/lib/push/notify.js", () => ({
  notifyParentsOfAlert: vi.fn(async () => { sent.events.push("push"); }),
}));

const { prisma } = await import("../src/db.js");
const { incompleteDedupeKey } = await import("../src/lib/deviceSetup.js");
const { storeAlertOnce } = await import("../src/lib/alerts.js");
const { AWAIT_REPORT, completeDeviceSetupIfReady, raisePhoneSetupNotice, withSetupOpen } = await import("../src/lib/deviceSetupTransitions.js");
// A completed pairing's late notice is either dropped or kept queued on the phone (osra-security#82); never an alert.
const NOT_AN_ALERT = [null, "await_report"];

const describeDatabase = databaseUrl ? describe.sequential : describe.skip;
const apiRoot = fileURLToPath(new URL("..", import.meta.url));
const pnpm = process.platform === "win32" ? "pnpm.cmd" : "pnpm";

const SEVEN = {
  accessibility: "granted", usage_access: "granted", overlay: "granted", device_admin: "granted",
  web_filter: "granted", location: "granted", private_dns: "granted",
} as const;
const caps = (notificationListener: string) => ({
  client: { app: "child-android", version: "0.2.0", build: 42, flavour: "full" },
  grants: { ...SEVEN, notification_listener: notificationListener },
  features: {},
});
const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));
async function stateAfter(promise: Promise<unknown>, ms = 400) {
  return Promise.race([promise.then(() => "settled", () => "settled"), sleep(ms).then(() => "pending")]);
}
function gate() {
  let open!: () => void;
  const opened = new Promise<void>((resolve) => { open = resolve; });
  return { open, opened };
}

async function pairing(setupCompletedAt: Date | null, notificationListener: string) {
  const family = await prisma.family.create({ data: { name: "Setup Order Test", region: "EU" } });
  const child = await prisma.child.create({ data: { familyId: family.id, displayName: "Test Child", birthYear: 2015 } });
  const pairedAt = new Date(Date.now() - 60 * 60_000);
  const device = await prisma.device.create({
    data: {
      childId: child.id, platform: "android", model: "Test Phone", osVersion: "14",
      pairedAt, setupCompletedAt, capabilities: caps(notificationListener),
    },
  });
  const transition = { ...device, child: { familyId: family.id, displayName: child.displayName } };
  const notice = {
    childId: child.id,
    familyId: family.id,
    deviceId: device.id,
    severity: "warning" as const,
    category: "tamper",
    title: "Setup is not finished yet",
    body: "Some required permissions are still missing on this device. Protection will start once setup finishes.",
    metadata: { type: "setup_incomplete_permissions", missingGrants: "NOTIFICATION_LISTENER" },
    dedupeKey: incompleteDedupeKey(device.id),
    childName: child.displayName,
  };
  return { device, transition, notice, pairedAt };
}

const noticeRows = (deviceId: string) =>
  prisma.alert.findMany({ where: { deviceId, category: "tamper", dedupeKey: incompleteDedupeKey(deviceId) } });
const deviceNow = (id: string) => prisma.device.findUniqueOrThrow({ where: { id } });

describeDatabase("setup completion and the setup notice on real Postgres (osra-security#87, #1230)", () => {
  beforeAll(async () => {
    await prisma.$executeRawUnsafe(`DROP SCHEMA IF EXISTS "${SCHEMA}" CASCADE`);
    const throughCmd = process.platform === "win32";
    const args = ["exec", "prisma", "migrate", "deploy"];
    await execFileAsync(
      throughCmd ? process.env.ComSpec ?? "cmd.exe" : pnpm,
      throughCmd ? ["/d", "/s", "/c", pnpm, ...args] : args,
      { cwd: apiRoot, env: { ...process.env, DATABASE_URL: schemaUrl }, maxBuffer: 4 * 1024 * 1024 },
    );
  }, 120_000);

  beforeEach(() => {
    sent.events.length = 0;
  });

  afterAll(async () => {
    await prisma.$executeRawUnsafe(`DROP SCHEMA IF EXISTS "${SCHEMA}" CASCADE`).catch(() => undefined);
    await prisma.$disconnect();
  });

  it("completion committed first: a later phone notice writes nothing", async () => {
    const { device, transition, notice, pairedAt } = await pairing(null, "granted");
    expect(await completeDeviceSetupIfReady(transition, caps("granted"), new Date())).toBe(true);
    sent.events.length = 0;
    expect(NOT_AN_ALERT).toContain(await raisePhoneSetupNotice(device.id, pairedAt, notice));
    expect(await noticeRows(device.id)).toHaveLength(0);
    expect(sent.events).toEqual([]);
  });

  it("completion that commits while the notice waits on the lock wins: the notice sees it and writes nothing", async () => {
    const { device, notice, pairedAt } = await pairing(null, "granted");
    const held = gate();
    const locked = gate();
    // Completion's claim, held open: it owns the row until we commit it.
    const completion = prisma.$transaction(async (tx) => {
      await tx.$executeRaw`UPDATE "Device" SET "setupCompletedAt" = now() WHERE "id" = ${device.id}`;
      locked.open();
      await held.opened;
    }, { timeout: 20_000 });
    await locked.opened;
    const raised = raisePhoneSetupNotice(device.id, pairedAt, notice);
    expect(await stateAfter(raised)).toBe("pending");
    held.open();
    await completion;
    expect(NOT_AN_ALERT).toContain(await raised);
    expect(await noticeRows(device.id)).toHaveLength(0);
    expect(sent.events).toEqual([]);
  });

  it("a notice holding the lock makes completion wait; the notice commits first, then completion", async () => {
    const { device, transition, notice } = await pairing(null, "granted");
    const held = gate();
    const locked = gate();
    const order: string[] = [];
    const noticeTx = withSetupOpen(device.id, async (tx) => {
      const stored = await storeAlertOnce(notice, tx);
      locked.open();
      await held.opened;
      return stored;
    }).then((stored) => { order.push("notice committed"); return stored; });
    await locked.opened;
    const completion = completeDeviceSetupIfReady(transition, caps("granted"), new Date())
      .then((done) => { order.push("completion"); return done; });
    expect(await stateAfter(completion)).toBe("pending");
    // Nothing is published or pushed while the notice transaction is open.
    expect(sent.events).toEqual([]);
    held.open();
    const stored = await noticeTx;
    expect(await completion).toBe(true);
    expect(order).toEqual(["notice committed", "completion"]);
    expect(stored?.deduplicated).toBe(false);
    expect(await noticeRows(device.id)).toHaveLength(1);
    expect((await deviceNow(device.id)).setupCompletedAt).not.toBeNull();
  });

  it("a rolled-back notice transaction leaves no row and dispatches nothing", async () => {
    const { device, notice } = await pairing(null, "missing");
    await expect(withSetupOpen(device.id, async (tx) => {
      await storeAlertOnce(notice, tx);
      throw new Error("abort after write");
    })).rejects.toThrow("abort after write");
    expect(await noticeRows(device.id)).toHaveLength(0);
    expect(sent.events).toEqual([]);
  });

  it("upgrade: a completed pairing missing a newly required grant gets one row and one push, latch intact", async () => {
    const completedAt = new Date(Date.now() - 30 * 60_000);
    const { device, notice, pairedAt } = await pairing(completedAt, "missing");
    const first = await raisePhoneSetupNotice(device.id, pairedAt, notice);
    expect(first?.deduplicated).toBe(false);
    expect(sent.events).toEqual(["publish", "push"]);
    const again = await raisePhoneSetupNotice(device.id, pairedAt, notice);
    expect(again?.deduplicated).toBe(true);
    expect(sent.events).toEqual(["publish", "push"]);
    expect(await noticeRows(device.id)).toHaveLength(1);
    expect((await deviceNow(device.id)).setupCompletedAt?.getTime()).toBe(completedAt.getTime());
  });

  it("stale retry: kept queued until a report after it shows every grant, then dropped; nothing written", async () => {
    const { device, notice, pairedAt } = await pairing(new Date(Date.now() - 30 * 60_000), "granted");
    expect(await raisePhoneSetupNotice(device.id, pairedAt, notice)).toBe(AWAIT_REPORT);
    await prisma.device.update({ where: { id: device.id }, data: { capabilitiesReportedAt: new Date(Date.now() + 1_000) } });
    expect(await raisePhoneSetupNotice(device.id, pairedAt, notice)).toBeNull();
    expect(await noticeRows(device.id)).toHaveLength(0);
    expect(sent.events).toEqual([]);
  });
});
