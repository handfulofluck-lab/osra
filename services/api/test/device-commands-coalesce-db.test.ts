import { execFile } from "node:child_process";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import { afterAll, beforeAll, describe, expect, it, vi } from "vitest";

/**
 * Codex (#1237 [Sat] 1, round 2, comment 7205649981): overlapping rules saves on a real Postgres. The coalesced
 * enqueue holds a per-(device, type) advisory lock and writes with a compare-and-set on (pending, revision), so the
 * newest adult is the phone's last word in every timing. Runs on the loopback, trust-only osra_test_* database CI
 * provides (OSRA_TEST_DATABASE_URL), in its own schema. Synthetic rows only.
 */
const execFileAsync = promisify(execFile);
const databaseUrl = process.env.OSRA_TEST_DATABASE_URL;
const SCHEMA = "device_cmd_1237";
if (process.env.OSRA_REQUIRE_DATABASE_TESTS === "1" && !databaseUrl) {
  throw new Error("OSRA_TEST_DATABASE_URL is required when OSRA_REQUIRE_DATABASE_TESTS=1");
}
const target = databaseUrl ? new URL(databaseUrl) : undefined;
if (target && (!["127.0.0.1", "localhost", "::1"].includes(target.hostname) ||
    !/^\/osra_test_[a-z0-9_]+$/.test(target.pathname) || target.password)) {
  throw new Error("The device command tests require a dedicated, trust-only osra_test_* database on loopback");
}
const schemaUrl = target ? (() => { const u = new URL(target.toString()); u.searchParams.set("schema", SCHEMA); return u.toString(); })() : "";

vi.mock("../src/db.js", async () => {
  const { PrismaClient } = await import("@prisma/client");
  const raw = process.env.OSRA_TEST_DATABASE_URL;
  let url = "postgresql://postgres@127.0.0.1:5432/osra_test_unused";
  if (raw) {
    const u = new URL(raw);
    u.searchParams.set("schema", "device_cmd_1237");
    url = u.toString();
  }
  return { prisma: new PrismaClient({ datasources: { db: { url } } }) };
});
vi.mock("../src/redis.js", () => ({ publishJson: vi.fn(async () => undefined) }));
vi.mock("../src/lib/push/notify.js", () => ({ wakeDeviceDetached: vi.fn() }));

const { prisma } = await import("../src/db.js");
const { claimPendingCommands, enqueueDeviceCommand } = await import("../src/lib/deviceCommands.js");

const describeDatabase = databaseUrl ? describe.sequential : describe.skip;
const apiRoot = fileURLToPath(new URL("..", import.meta.url));
const pnpm = process.platform === "win32" ? "pnpm.cmd" : "pnpm";

async function device() {
  const family = await prisma.family.create({ data: { name: "Command Order Test", region: "EU" } });
  const child = await prisma.child.create({ data: { familyId: family.id, displayName: "Test Child", birthYear: 2015 } });
  return prisma.device.create({ data: { childId: child.id, platform: "android", model: "Test Phone", osVersion: "14", pairedAt: new Date() } });
}
const save = (deviceId: string, byName: string, rulesVersion: number) =>
  enqueueDeviceCommand(deviceId, "rules_updated", { reason: "rules_changed", rulesVersion, byName });
const rows = (deviceId: string) =>
  prisma.deviceCommand.findMany({ where: { deviceId, type: "rules_updated" }, orderBy: { createdAt: "asc" } });
const payloadOf = (r: { payload: unknown }) => r.payload as { rulesVersion?: number; byName?: string };

describeDatabase("coalesced rules commands on real Postgres (#1237)", () => {
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

  afterAll(async () => {
    await prisma.$executeRawUnsafe(`DROP SCHEMA IF EXISTS "${SCHEMA}" CASCADE`).catch(() => undefined);
    await prisma.$disconnect();
  });

  it.each([
    ["newer first", [["Mama Sara", 5], ["Baba", 4]]],
    ["older first", [["Baba", 4], ["Mama Sara", 5]]],
  ] as const)("overlapping saves on one pending row (%s): one row, the newest adult", async (_label, order) => {
    const d = await device();
    await save(d.id, "Dad", 3);
    await Promise.all(order.map(([name, v]) => save(d.id, name, v)));
    const all = await rows(d.id);
    expect(all).toHaveLength(1);
    expect(all[0].status).toBe("pending");
    expect(payloadOf(all[0])).toMatchObject({ rulesVersion: 5, byName: "Mama Sara" });
  });

  it("many overlapping saves in random order: the highest revision is the phone's last word", async () => {
    const d = await device();
    const versions = [7, 3, 9, 1, 8, 2, 6, 4, 5];
    await Promise.all(versions.map((v) => save(d.id, `Adult ${v}`, v)));
    const all = await rows(d.id);
    expect(all.filter((r) => r.status === "pending")).toHaveLength(1);
    expect(payloadOf(all[all.length - 1])).toMatchObject({ rulesVersion: 9, byName: "Adult 9" });
  });

  it("the newest save already drained: an older save that lands after it adds nothing", async () => {
    const d = await device();
    await save(d.id, "Mama Sara", 5);
    expect(await claimPendingCommands(d.id)).toHaveLength(1);
    await save(d.id, "Baba", 4);
    const all = await rows(d.id);
    expect(all).toHaveLength(1);
    expect(all[0].status).toBe("delivered");
    expect(payloadOf(all[0])).toMatchObject({ rulesVersion: 5, byName: "Mama Sara" });
  });

  it("drains racing saves: every newer revision reaches the phone and the last one claimed is the newest", async () => {
    const d = await device();
    const claimed: Array<{ rulesVersion?: number }> = [];
    const drainer = (async () => {
      for (let i = 0; i < 12; i += 1) {
        for (const m of await claimPendingCommands(d.id)) claimed.push(m.payload as { rulesVersion?: number });
        await new Promise((resolve) => setTimeout(resolve, 5));
      }
    })();
    await Promise.all([1, 2, 3, 4, 5, 6].map((v) => save(d.id, `Adult ${v}`, v)));
    await drainer;
    for (const m of await claimPendingCommands(d.id)) claimed.push(m.payload as { rulesVersion?: number });
    expect(claimed.length).toBeGreaterThan(0);
    expect(claimed[claimed.length - 1].rulesVersion).toBe(6);
    // Never a step backwards: each claimed revision is newer than the one before it.
    const seen = claimed.map((c) => c.rulesVersion ?? 0);
    expect([...seen].sort((a, b) => a - b)).toEqual(seen);
  });
});
