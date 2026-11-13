import { execFile } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";

const execFileAsync = promisify(execFile);
const apiRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const databaseUrl = process.env.OSRA_TEST_DATABASE_URL;
const psql = process.env.PSQL_BIN ?? "psql";
const pnpm = process.platform === "win32" ? "pnpm.cmd" : "pnpm";
const LEGACY_DEMO_EMAIL = "demo@familyshield.dev";
const CURRENT_DEMO_EMAIL = "demo@osratech.com";

if (process.env.OSRA_REQUIRE_DATABASE_TESTS === "1" && !databaseUrl) {
  throw new Error("OSRA_TEST_DATABASE_URL is required when OSRA_REQUIRE_DATABASE_TESTS=1");
}

const target = databaseUrl ? new URL(databaseUrl) : undefined;
if (target) {
  if (!["127.0.0.1", "localhost", "::1"].includes(target.hostname) ||
      !/^\/osra_test_[a-z0-9_]+$/.test(target.pathname) || target.password) {
    throw new Error("The demo cleanup tests require a dedicated, trust-only osra_test_* database on loopback");
  }
}
const psqlConnection = target ? [
  "-h", target.hostname.replace(/^\[|\]$/g, ""),
  "-p", target.port || "5432",
  "-U", decodeURIComponent(target.username || "postgres"),
  "-d", target.pathname.slice(1),
] : [];

const describeDatabase = databaseUrl ? describe.sequential : describe.skip;

async function run(command: string, args: string[], env?: NodeJS.ProcessEnv) {
  const label = `${path.basename(command)} ${args[0] ?? ""}`;
  const throughCmd = command === pnpm && process.platform === "win32";
  console.log(`[demo-db] start ${label}`);
  try {
    const result = await execFileAsync(
      throughCmd ? process.env.ComSpec ?? "cmd.exe" : command,
      throughCmd ? ["/d", "/s", "/c", command, ...args] : args,
      {
        cwd: apiRoot,
        env: { ...process.env, ...env },
        maxBuffer: 4 * 1024 * 1024,
      },
    );
    console.log(`[demo-db] done ${label}`);
    return result;
  } catch (error) {
    const detail = error as Error & { stdout?: string; stderr?: string };
    throw new Error(`${command} ${args.join(" ")} failed: ${detail.message}\n${detail.stdout ?? ""}\n${detail.stderr ?? ""}`);
  }
}

async function sql(query: string) {
  const { stdout } = await run(psql, [...psqlConnection, "-X", "-A", "-t", "-v", "ON_ERROR_STOP=1", "-c", query]);
  return stdout.trim().replace(/\r\n/g, "\n");
}

async function cleanup() {
  return run(psql, [
    ...psqlConnection, "-X", "-v", "ON_ERROR_STOP=1", "-v", "apply=1",
    "-f", path.join(apiRoot, "scripts", "cleanup-test-data.sql"),
  ]);
}

async function seed() {
  await run(pnpm, ["exec", "tsx", "scripts/seed.ts"], {
    DATABASE_URL: databaseUrl,
    NODE_ENV: "test",
  });
}

async function family(id: string, name: string) {
  await sql(`INSERT INTO "Family" (id, name, region) VALUES ('${id}', '${name}', 'US')`);
}

async function parent(id: string, familyId: string, email: string, passwordHash = "test-only-hash") {
  await sql(`INSERT INTO "Parent" (id, "familyId", email, "passwordHash", "displayName")
    VALUES ('${id}', '${familyId}', '${email}', '${passwordHash}', 'Test Parent')`);
}

async function child(id: string, familyId: string, name: string) {
  await sql(`INSERT INTO "Child" (id, "familyId", "displayName", "birthYear")
    VALUES ('${id}', '${familyId}', '${name}', 2015)`);
}

async function childNames() {
  const rows = await sql('SELECT "displayName" FROM "Child" ORDER BY "displayName"');
  return rows ? rows.split("\n") : [];
}

describeDatabase("demo seed and cleanup against real Postgres", () => {
  beforeAll(async () => {
    await run(psql, [...psqlConnection, "-X", "-v", "ON_ERROR_STOP=1", "-c", "DROP SCHEMA public CASCADE; CREATE SCHEMA public;"]);
    await run(pnpm, ["exec", "prisma", "migrate", "deploy"], { DATABASE_URL: databaseUrl });
  }, 120_000);

  beforeEach(async () => {
    await sql('TRUNCATE "Family" CASCADE');
  });

  afterAll(async () => {
    if (!databaseUrl) return;
    await run(psql, [...psqlConnection, "-X", "-v", "ON_ERROR_STOP=1", "-c", "DROP SCHEMA public CASCADE; CREATE SCHEMA public;"]);
  });

  it("migrates an old-seed owner once across two runs", async () => {
    await family("legacy-family", "Demo Family");
    await parent("legacy-parent", "legacy-family", LEGACY_DEMO_EMAIL, "old-seed-hash");

    await seed();
    await seed();

    expect(await sql(`SELECT id || '|' || email || '|' || "passwordHash" || '|' || "familyId"
      FROM "Parent" WHERE email IN ('${LEGACY_DEMO_EMAIL}', '${CURRENT_DEMO_EMAIL}')`))
      .toBe("legacy-parent|demo@osratech.com|old-seed-hash|legacy-family");
    expect(await sql("SELECT count(*) FROM \"Parent\"")).toBe("1");
    expect(await sql("SELECT count(*) FROM \"Child\" WHERE \"displayName\" = 'Alex'")).toBe("1");
  }, 60_000);

  it("refuses apply without exactly one current demo parent", async () => {
    await family("demo-family", "Demo Family");
    await parent("legacy-parent", "demo-family", LEGACY_DEMO_EMAIL);
    await child("demo-alex", "demo-family", "Alex");
    await child("demo-extra", "demo-family", "Test Extra");
    await family("review-family", "Play Review Family");
    await parent("review-parent", "review-family", "reviewer@example.net");
    await child("review-child", "review-family", "Review Child");
    await family("qa-family", "QA Family A");
    await parent("qa-parent", "qa-family", "qa-test@example.com");
    await child("qa-child", "qa-family", "Test Child");

    const result = await cleanup();

    expect(result.stdout).not.toContain("=== APPLYING ===");
    expect(result.stdout).toContain("exactly one current demo parent");
    expect(await childNames()).toEqual(["Alex", "Review Child", "Test Child", "Test Extra"]);
    expect(await sql("SELECT count(*) FROM \"Parent\"")).toBe("3");
  }, 60_000);

  it("deletes only explicit test data and preserves legitimate families", async () => {
    await family("demo-family", "Demo Family");
    await parent("demo-parent", "demo-family", CURRENT_DEMO_EMAIL);
    await child("demo-alex", "demo-family", "Alex");
    await child("demo-extra", "demo-family", "Test Extra");
    await family("review-family", "Play Review Family");
    await parent("review-parent", "review-family", "reviewer@example.net");
    await child("review-child", "review-family", "Review Child");
    await family("review-orphan", "Play Review Orphan");
    await family("qa-family", "QA Family A");
    await parent("qa-parent", "qa-family", "qa-test@example.com");
    await child("qa-child", "qa-family", "Test Child");
    await family("qa-orphan", "QA Family B");
    await family("e2e-family", "E2E Cross Family");
    await parent("e2e-parent", "e2e-family", "e2e-crossfamily@example.com");
    await child("e2e-child", "e2e-family", "E2E Child");

    await cleanup();

    expect(await sql('SELECT name FROM "Family" ORDER BY name')).toBe("Demo Family\nPlay Review Family\nPlay Review Orphan");
    expect(await childNames()).toEqual(["Alex", "Review Child"]);
    expect(await sql("SELECT count(*) FROM \"Parent\"")).toBe("2");
  }, 60_000);
});
