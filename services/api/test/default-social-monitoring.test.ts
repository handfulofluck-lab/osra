import { existsSync, readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import { DEFAULT_RULESET, defaultRuleSetRow } from "../src/lib/defaultRules.js";

const expected = {
  whatsapp: true,
  instagram: true,
  tiktok: true,
  snapchat: true,
  twitter: true,
  discord: true,
  roblox: true,
  line: true,
  youtube: true,
  telegram: true,
  reddit: true,
  messenger: true,
};

describe("server-default social monitoring (#1142)", () => {
  it("persists every canonical app ON in the same child-creation rule row", () => {
    // Mutant: an empty map, a missing key, or a client-side follow-up PATCH leaves the first
    // staging scan without an explicit saved setting.
    expect(DEFAULT_RULESET.socialMonitoring).toEqual(expected);
    expect(defaultRuleSetRow("child-1").socialMonitoring).toEqual(expected);
  });

  it("backfills only empty maps without overwriting a parent's existing choices", () => {
    const path = fileURLToPath(new URL("../prisma/migrations/0045_default_social_monitoring/migration.sql", import.meta.url));
    expect(existsSync(path)).toBe(true);
    const sql = existsSync(path) ? readFileSync(path, "utf8") : "";
    expect(sql).toContain('UPDATE "RuleSet"');
    expect(sql).toContain('WHERE "socialMonitoring" = \'{}\'::jsonb');
    expect(sql).toContain('"whatsapp": true');
    expect(sql).toContain('"messenger": true');
    expect(sql).not.toMatch(/DELETE|DROP TABLE/i);
  });
});
