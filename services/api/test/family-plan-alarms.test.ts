// The production alarms for #811's entitlement warnings match on the event name, so a renamed event would
// silence its alarm without failing anything. This reads both sides (Fable R3 on #816).
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";

const read = (relative: string) => readFileSync(fileURLToPath(new URL(relative, import.meta.url)), "utf8");
const terraform = read("../../../infra/terraform/env/family_plan_alarms.tf");
const source = read("../src/lib/entitlement.ts");

describe("family plan alarms (#816)", () => {
  const alarmed = [...terraform.matchAll(/^\s*event\s*=\s*"([a-z_]+)"/gm)].map((m) => m[1]);

  it("alarms on both entitlement warnings", () => {
    expect(alarmed.sort()).toEqual(["family_plan_missing_expiry", "family_plan_recovery_ceiling"]);
  });

  it.each(["family_plan_missing_expiry", "family_plan_recovery_ceiling"])("entitlement.ts still emits %s", (event) => {
    expect(source).toContain(`"${event}"`);
  });

  it("every family_plan_ event entitlement.ts emits has an alarm", () => {
    const emitted = new Set([...source.matchAll(/"(family_plan_[a-z_]+)"/g)].map((m) => m[1]));
    expect([...emitted].sort()).toEqual(alarmed.sort());
  });

  it("the filter pattern is built from the event field the API writes", () => {
    expect(terraform).toContain('pattern        = "{ $.event = \\"${each.value.event}\\" }"');
    expect(source).toMatch(/JSON\.stringify\(\{ event: message/);
  });
});
