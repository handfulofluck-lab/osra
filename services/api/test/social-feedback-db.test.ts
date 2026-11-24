import { execFile } from "node:child_process";
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

const describeDatabase = databaseUrl ? describe : describe.skip;
const apiRoot = fileURLToPath(new URL("..", import.meta.url));
const pnpm = process.platform === "win32" ? "pnpm.cmd" : "pnpm";
let db: PrismaClient;
let migrated = false;

describeDatabase("social feedback database cascade (#1065)", () => {
  beforeAll(async () => {
    db = new PrismaClient({ datasources: { db: { url: databaseUrl } } });
    await db.$executeRawUnsafe("DROP SCHEMA public CASCADE");
    await db.$executeRawUnsafe("CREATE SCHEMA public");
    const throughCmd = process.platform === "win32";
    await execFileAsync(
      throughCmd ? process.env.ComSpec ?? "cmd.exe" : pnpm,
      throughCmd ? ["/d", "/s", "/c", pnpm, "exec", "prisma", "migrate", "deploy"] : ["exec", "prisma", "migrate", "deploy"],
      { cwd: apiRoot, env: { ...process.env, DATABASE_URL: databaseUrl }, maxBuffer: 4 * 1024 * 1024 },
    );
    migrated = true;
  }, 120_000);

  afterAll(async () => {
    if (!db) return;
    if (migrated) {
      await db.child.deleteMany();
      await db.parent.deleteMany();
      await db.family.deleteMany();
    }
    await db.$disconnect();
  });

  it("deletes a persisted vote when its social event is deleted", async () => {
    const family = await db.family.create({ data: { name: "Feedback DB Test", region: "EU" } });
    const parent = await db.parent.create({
      data: { familyId: family.id, email: "feedback-db@example.invalid", passwordHash: "not-a-login", displayName: "DB Parent" },
    });
    const child = await db.child.create({
      data: { familyId: family.id, displayName: "DB Child", birthYear: 2015 },
    });
    const event = await db.socialEvent.create({
      data: { childId: child.id, app: "whatsapp", severity: "warning", modelVersion: "checkpoint-test", lang: "en", path: "own" },
    });
    const vote = await db.socialEventFeedback.create({
      data: { socialEventId: event.id, parentId: parent.id, verdict: "concerning", parentName: parent.displayName },
    });
    expect(await db.socialEventFeedback.findUnique({ where: { id: vote.id } })).not.toBeNull();

    await db.socialEvent.delete({ where: { id: event.id } });

    expect(await db.socialEventFeedback.findUnique({ where: { id: vote.id } })).toBeNull();
    await db.child.delete({ where: { id: child.id } });
    await db.parent.delete({ where: { id: parent.id } });
    await db.family.delete({ where: { id: family.id } });
  });
});
