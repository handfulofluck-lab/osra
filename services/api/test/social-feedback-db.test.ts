import { execFile } from "node:child_process";
import { cp, mkdir, mkdtemp, readdir, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { promisify } from "node:util";
import { fileURLToPath } from "node:url";
import { PrismaClient } from "@prisma/client";
import { afterAll, beforeAll, describe, expect, it } from "vitest";

const execFileAsync = promisify(execFile);
const databaseUrl = process.env.OSRA_FEEDBACK_DATABASE_URL;
const target = databaseUrl ? new URL(databaseUrl) : undefined;
if (target && (!["127.0.0.1", "localhost", "::1"].includes(target.hostname) || target.pathname !== "/osra_feedback_1065")) {
  throw new Error("The social feedback database test requires only loopback database osra_feedback_1065");
}
if (process.env.OSRA_REQUIRE_DATABASE_TESTS === "1" && !databaseUrl) {
  throw new Error("OSRA_FEEDBACK_DATABASE_URL is required when OSRA_REQUIRE_DATABASE_TESTS=1");
}

const describeDatabase = databaseUrl ? describe.sequential : describe.skip;
const apiRoot = fileURLToPath(new URL("..", import.meta.url));
const pnpm = process.platform === "win32" ? "pnpm.cmd" : "pnpm";
let db: PrismaClient;
let migrated = false;
let legacyRoot: string | undefined;

async function migrateDeploy(schema?: string) {
  const throughCmd = process.platform === "win32";
  const args = ["exec", "prisma", "migrate", "deploy", ...(schema ? ["--schema", schema] : [])];
  return execFileAsync(
    throughCmd ? process.env.ComSpec ?? "cmd.exe" : pnpm,
    throughCmd ? ["/d", "/s", "/c", pnpm, ...args] : args,
    { cwd: apiRoot, env: { ...process.env, DATABASE_URL: databaseUrl }, maxBuffer: 4 * 1024 * 1024 },
  );
}

async function createFamilyEvent() {
  const family = await db.family.create({ data: { name: "Feedback DB Test", region: "EU" } });
  const parent = await db.parent.create({
    data: { familyId: family.id, email: `feedback-${crypto.randomUUID()}@example.invalid`, passwordHash: "not-a-login", displayName: "DB Parent" },
  });
  const child = await db.child.create({ data: { familyId: family.id, displayName: "DB Child", birthYear: 2015 } });
  const event = await db.socialEvent.create({
    data: { childId: child.id, app: "whatsapp", severity: "warning", modelVersion: "checkpoint-test", lang: "en", path: "own" },
  });
  return { family, parent, child, event };
}

async function removeFamilyEvent(ids: { family: string; parent: string; child: string }) {
  await db.child.deleteMany({ where: { id: ids.child } });
  await db.parent.deleteMany({ where: { id: ids.parent } });
  await db.family.deleteMany({ where: { id: ids.family } });
}

describeDatabase("social feedback database migration and cascade (#1065)", () => {
  beforeAll(async () => {
    db = new PrismaClient({ datasources: { db: { url: databaseUrl } } });
    await db.$executeRawUnsafe("DROP SCHEMA public CASCADE");
    await db.$executeRawUnsafe("CREATE SCHEMA public");
    legacyRoot = await mkdtemp(path.join(tmpdir(), "osra-feedback-0042-"));
    await cp(path.join(apiRoot, "prisma", "schema.prisma"), path.join(legacyRoot, "schema.prisma"));
    await mkdir(path.join(legacyRoot, "migrations"));
    const migrations = path.join(apiRoot, "prisma", "migrations");
    for (const entry of await readdir(migrations, { withFileTypes: true })) {
      if (entry.isDirectory() && entry.name < "0043") {
        await cp(path.join(migrations, entry.name), path.join(legacyRoot, "migrations", entry.name), { recursive: true });
      }
    }
    await migrateDeploy(path.join(legacyRoot, "schema.prisma"));
  }, 120_000);

  afterAll(async () => {
    if (db) {
      if (migrated) {
        await db.child.deleteMany();
        await db.parent.deleteMany();
        await db.family.deleteMany();
      }
      await db.$disconnect();
    }
    if (legacyRoot) await rm(legacyRoot, { recursive: true, force: true });
  });

  it("upgrades a real 0042 schema by deleting only orphaned events and preserving valid events", async () => {
    await db.$executeRawUnsafe('INSERT INTO "Family" ("id", "name", "region") VALUES (\'legacy-family\', \'Legacy\', \'EU\')');
    await db.$executeRawUnsafe('INSERT INTO "Parent" ("id", "familyId", "email", "passwordHash", "displayName") VALUES (\'legacy-parent\', \'legacy-family\', \'legacy-parent@example.invalid\', \'not-a-login\', \'Parent\')');
    await db.$executeRawUnsafe('INSERT INTO "Child" ("id", "familyId", "displayName", "birthYear") VALUES (\'legacy-child\', \'legacy-family\', \'Child\', 2015)');
    await db.$executeRawUnsafe('INSERT INTO "Child" ("id", "familyId", "displayName", "birthYear") VALUES (\'legacy-paused-child\', \'legacy-family\', \'Paused Child\', 2014)');
    await db.$executeRawUnsafe('INSERT INTO "ConsentRecord" ("id", "childId", "parentId", "method", "jurisdiction", "revokedAt") VALUES (\'legacy-revoked-consent\', \'legacy-paused-child\', \'legacy-parent\', \'sms_plus\', \'US\', CURRENT_TIMESTAMP)');
    await db.$executeRawUnsafe('INSERT INTO "SocialEvent" ("id", "childId", "app") VALUES (\'legacy-valid\', \'legacy-child\', \'whatsapp\')');
    await db.$executeRawUnsafe('INSERT INTO "SocialEvent" ("id", "childId", "app") VALUES (\'legacy-paused\', \'legacy-paused-child\', \'whatsapp\')');
    await db.$executeRawUnsafe('INSERT INTO "SocialEvent" ("id", "childId", "app", "previewCipher") VALUES (\'legacy-orphan\', \'missing-child\', \'whatsapp\', \'secret-message-evidence\')');

    const migrationOutput = await migrateDeploy();
    migrated = true;

    expect(await db.socialEvent.findUnique({ where: { id: "legacy-orphan" } })).toBeNull();
    expect(await db.socialEvent.findUnique({ where: { id: "legacy-valid" } })).not.toBeNull();
    expect(await db.socialEvent.findUnique({ where: { id: "legacy-paused" } })).not.toBeNull();
    const remainingOrphans = await db.$queryRawUnsafe<Array<{ count: number }>>(
      'SELECT count(*)::int AS count FROM "SocialEvent" AS event WHERE NOT EXISTS (SELECT 1 FROM "Child" AS child WHERE child."id" = event."childId")',
    );
    expect(remainingOrphans).toEqual([{ count: 0 }]);
    // Prisma's migrate CLI suppresses PostgreSQL NOTICEs, so the real privacy check is the row count
    // above plus the static NOTICE assertion in social-feedback.test.ts. No deploy output may leak data.
    const output = migrationOutput.stdout + migrationOutput.stderr;
    for (const privateValue of ["legacy-orphan", "missing-child", "secret-message-evidence", "whatsapp"]) {
      expect(output).not.toContain(privateValue);
    }
    const orphanTables = await db.$queryRawUnsafe<Array<{ tableName: string }>>(
      "SELECT table_name AS \"tableName\" FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'SocialEventOrphan'",
    );
    expect(orphanTables).toEqual([]);
  }, 120_000);

  it("applies different concurrent first verdicts atomically and keeps identical replay a no-op", async () => {
    const { writeSocialEventFeedback } = await import("../src/lib/socialFeedback.js");
    const { family, parent, child, event } = await createFamilyEvent();
    const input = {
      socialEventId: event.id,
      parentId: parent.id,
      parentName: parent.displayName,
      modelVersion: "checkpoint-test",
      lang: "en",
      topCategory: "self_harm",
      topScore: 0.8,
      cutoff: 0.6,
      path: "own",
      severity: "warning",
    };

    await Promise.all([
      writeSocialEventFeedback({ ...input, verdict: "concerning" }, db),
      writeSocialEventFeedback({ ...input, verdict: "not_concerning" }, db),
    ]);

    const where = { socialEventId_parentId: { socialEventId: event.id, parentId: parent.id } };
    const written = await db.socialEventFeedback.findUniqueOrThrow({ where });
    expect(["concerning", "not_concerning"]).toContain(written.verdict);
    expect(written.changeCount).toBe(1);
    const replayed = await writeSocialEventFeedback({ ...input, verdict: written.verdict }, db);
    expect(replayed.changeCount).toBe(1);
    expect(replayed.lastChangedAt).toEqual(written.lastChangedAt);
    await removeFamilyEvent({ family: family.id, parent: parent.id, child: child.id });
  });

  it("deletes a persisted vote when its social event is deleted", async () => {
    const { family, parent, child, event } = await createFamilyEvent();
    const vote = await db.socialEventFeedback.create({
      data: { socialEventId: event.id, parentId: parent.id, verdict: "concerning", parentName: parent.displayName },
    });
    expect(await db.socialEventFeedback.findUnique({ where: { id: vote.id } })).not.toBeNull();

    await db.socialEvent.delete({ where: { id: event.id } });

    expect(await db.socialEventFeedback.findUnique({ where: { id: vote.id } })).toBeNull();
    await removeFamilyEvent({ family: family.id, parent: parent.id, child: child.id });
  });

  it("deletes a child's social events and their votes when the child is deleted", async () => {
    const { family, parent, child, event } = await createFamilyEvent();
    const vote = await db.socialEventFeedback.create({
      data: { socialEventId: event.id, parentId: parent.id, verdict: "concerning", parentName: parent.displayName },
    });

    await db.child.delete({ where: { id: child.id } });

    expect(await db.socialEvent.findUnique({ where: { id: event.id } })).toBeNull();
    expect(await db.socialEventFeedback.findUnique({ where: { id: vote.id } })).toBeNull();
    await removeFamilyEvent({ family: family.id, parent: parent.id, child: child.id });
  });
});
