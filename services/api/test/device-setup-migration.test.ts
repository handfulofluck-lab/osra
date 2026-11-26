import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

const migration = readFileSync(new URL("../prisma/migrations/0046_device_setup_alerts/migration.sql", import.meta.url), "utf8");
const schema = readFileSync(new URL("../prisma/schema.prisma", import.meta.url), "utf8");

describe("0046 setup-alert migration (#1127)", () => {
  it("adds nullable completion and visible-by-default held state", () => {
    expect(migration).toContain('ALTER TABLE "Device" ADD COLUMN "setupCompletedAt" TIMESTAMPTZ(3)');
    expect(migration).toContain('ALTER TABLE "Alert" ADD COLUMN "heldDuringSetup" BOOLEAN NOT NULL DEFAULT false');
    expect(schema).toMatch(/setupCompletedAt\s+DateTime\?\s+@db\.Timestamptz\(3\)/);
    expect(schema).toMatch(/heldDuringSetup\s+Boolean\s+@default\(false\)/);
  });

  it("backfills only existing paired devices and never hides historical alerts", () => {
    // Mutants: dropping either predicate reopens setup on existing or abandoned-pending devices;
    // updating Alert to true would conceal the family's existing security evidence.
    expect(migration).toMatch(/UPDATE "Device"[\s\S]*SET "setupCompletedAt" = "pairedAt"/);
    expect(migration).toContain('WHERE "pairedAt" IS NOT NULL');
    expect(migration).toContain('AND "setupCompletedAt" IS NULL');
    expect(migration).not.toMatch(/UPDATE "Alert"/i);
  });
});
