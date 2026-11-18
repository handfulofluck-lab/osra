import { beforeEach, describe, expect, it, vi } from "vitest";
import { FEATURE_KEYS, GRANT_KEYS } from "@familyshield/shared-types";
import { CapabilitiesSchema, parseCapabilities, setupFor, withStoredGroups } from "../src/lib/capabilities.js";
import { deviceRoutes } from "../src/routes/devices.js";
import { buildApp, deviceHeader, prismaMock, resetPrismaMock } from "./helpers.js";

vi.mock("../src/db.js", async () => {
  const { prismaMock } = await import("./helpers.js");
  return { prisma: prismaMock };
});
vi.mock("ioredis", async () => {
  const { MockRedis } = await import("./helpers.js");
  return { Redis: MockRedis };
});

/**
 * ADR-0037 (5.5 PR B, #372): the iPhone reports its app groups as id + label + counts, never app names, bundle ids
 * or tokens. The schema lands before any phone sends the field, so an early report is never refused.
 *
 * Mutants: drop the iPhone-only rule → [only an iPhone may report groups]; accept a repeated id → [refuses a
 * repeated id]; accept an apps list → [refuses anything identifying]; a report without groups wipes them →
 * [a report without groups keeps the stored ones]; groups counted inside the 4 KB → [twenty Arabic-named groups fit];
 * the route merging only when `profiles` is missing (Claude's m8) → [an iPhone upload that carries profiles but not
 * groups keeps the stored groups]; no direction-control check → [refuses Unicode direction controls …].
 */

const NOW = Date.UTC(2026, 10, 11, 12, 0, 0);
const DEVICE = { id: "dev-1", childId: "child-1", child: { familyId: "fam-1" } };
const ID_A = "6f1c9a2e-0b7d-4c55-9a51-2f3c8e0d1a77";
const ID_B = "0d4b5c6a-7e8f-4a1b-9c2d-3e4f5a6b7c8d";

function report(overrides: Record<string, unknown> = {}) {
  return {
    client: { app: "child-ios", version: "0.1.0", build: 1, flavour: "testflight" },
    grants: { family_controls: "granted" },
    features: { app_blocking: "ready" },
    ...overrides,
  };
}

const group = (overrides: Record<string, unknown> = {}) => ({ id: ID_A, label: "Games", apps: 5, categories: 1, sites: 0, ...overrides });
const ok = (groups: unknown, extra: Record<string, unknown> = {}) => CapabilitiesSchema.safeParse(report({ groups, ...extra })).success;

describe("groups — the shape", () => {
  it("accepts id, label and counts, an empty list, and a report without groups", () => {
    expect(ok([group()])).toBe(true);
    expect(ok([group(), group({ id: ID_B, label: "ألعاب" })])).toBe(true);
    expect(ok([])).toBe(true);
    expect(CapabilitiesSchema.safeParse(report()).success).toBe(true);
  });

  it("only an iPhone may report groups", () => {
    const android = { client: { app: "child-android", version: "0.2.0", build: 2, flavour: "play" } };
    expect(ok([group()], android)).toBe(false);
    expect(CapabilitiesSchema.safeParse(report(android)).success).toBe(true);
  });

  it("checks the label again: length, control characters, edge whitespace", () => {
    expect(ok([group({ label: "x".repeat(40) })])).toBe(true);
    expect(ok([group({ label: "ع".repeat(40) })])).toBe(true);
    expect(ok([group({ label: "x".repeat(41) })])).toBe(false);
    expect(ok([group({ label: "" })])).toBe(false);
    expect(ok([group({ label: "Ga\nmes" })])).toBe(false);
    expect(ok([group({ label: " Games" })])).toBe(false);
  });

  it("refuses Unicode direction controls, which could flip the text after the label on the parent's screen", () => {
    for (const ch of ["\u202e", "\u202a", "\u2066", "\u2069", "\u200f", "\u061c"]) {
      expect(ok([group({ label: `Ga${ch}mes` })])).toBe(false);
    }
    expect(ok([group({ label: "ألعاب Games" })])).toBe(true);
  });

  it("refuses a repeated id, a non-UUID id and more than 20 groups", () => {
    expect(ok([group(), group({ label: "Other" })])).toBe(false);
    expect(ok([group({ id: "games" })])).toBe(false);
    const many = Array.from({ length: 21 }, (_, i) => group({ id: `00000000-0000-4000-8000-${String(i).padStart(12, "0")}`, label: `g${i}` }));
    expect(ok(many)).toBe(false);
    expect(ok(many.slice(0, 20))).toBe(true);
  });

  it("refuses bad counts and anything identifying", () => {
    expect(ok([group({ apps: -1 })])).toBe(false);
    expect(ok([group({ apps: 1.5 })])).toBe(false);
    expect(ok([group({ apps: 10001 })])).toBe(false);
    expect(ok([group({ appNames: ["Calculator"] })])).toBe(false);
    expect(ok([group({ bundleIds: ["com.apple.calculator"] })])).toBe(false);
    expect(ok([group({ tokens: ["opaque"] })])).toBe(false);
  });
});

describe("groups — the byte caps", () => {
  it("twenty Arabic-named groups fit: groups are not counted inside the report's 4 KB", () => {
    const groups = Array.from({ length: 20 }, (_, i) => group({ id: `00000000-0000-4000-8000-${String(i).padStart(12, "0")}`, label: "ع".repeat(40) }));
    // A full report (every grant, every feature) plus twenty 40-letter Arabic labels passes 4 KB.
    // The phone's features only: `child_account_admin` is refused from an iPhone (ADR-0041 D5.5), so it would
    // measure that refusal instead of the cap.
    const full = report({
      groups,
      grants: Object.fromEntries(GRANT_KEYS.map((k) => [k, "not_applicable"])),
      features: Object.fromEntries(FEATURE_KEYS.filter((k) => k !== "child_account_admin").map((k) => [k, "unavailable"])),
    });
    expect(Buffer.byteLength(JSON.stringify(full))).toBeGreaterThan(4096);
    const parsed = parseCapabilities(full, "ios");
    expect(parsed.ok).toBe(true);
  });

  it("but the groups have their own cap, checked before parsing", () => {
    const parsed = parseCapabilities(report({ groups: [group({ padding: "x".repeat(9000) })] }), "ios");
    expect(parsed.ok).toBe(false);
    expect(parsed.ok ? "" : parsed.issue).toContain("groups is");
  });

  it("a failure message never repeats the label", () => {
    const parsed = parseCapabilities(report({ groups: [group({ label: "Secret name\n" })] }), "ios");
    expect(parsed.ok).toBe(false);
    expect(parsed.ok ? "" : parsed.issue).not.toContain("Secret name");
  });
});

describe("groups — storage and the parent's projection", () => {
  const stored = report({ groups: [group()] });

  it("a report without groups keeps the stored ones", () => {
    const next = CapabilitiesSchema.parse(report({ grants: { family_controls: "missing" } }));
    const merged = withStoredGroups(next, stored);
    expect(merged.groups).toEqual([group()]);
    expect(merged.grants).toEqual({ family_controls: "missing" });
  });

  it("a report with groups replaces them, including with none", () => {
    expect(withStoredGroups(CapabilitiesSchema.parse(report({ groups: [] })), stored).groups).toEqual([]);
  });

  it("setup shows the groups, and null when no report carried them", () => {
    const at = new Date(NOW - 60_000);
    expect(setupFor({ capabilities: stored, capabilitiesReportedAt: at }, NOW).groups).toEqual([group()]);
    expect(setupFor({ capabilities: report(), capabilitiesReportedAt: at }, NOW).groups).toBeNull();
    expect(setupFor({ capabilities: null, capabilitiesReportedAt: null }, NOW).groups).toBeNull();
  });
});

describe("groups — at the telemetry route", () => {
  beforeEach(() => resetPrismaMock());

  function withStored(capabilities: unknown) {
    prismaMock.device.findUnique.mockImplementation(async (args: { select?: { capabilities?: boolean } }) =>
      args?.select?.capabilities ? { capabilities } : DEVICE,
    );
    prismaMock.device.update.mockResolvedValue(DEVICE);
  }

  async function post(capabilities: unknown) {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    const res = await app.inject({
      method: "POST",
      url: "/v1/devices/dev-1/telemetry",
      headers: deviceHeader(app),
      payload: { capabilities },
    });
    return { res, written: prismaMock.device.update.mock.calls.at(-1)?.[0]?.data ?? {} };
  }

  it("an upload whose report omits groups keeps the stored groups", async () => {
    withStored(report({ groups: [group()] }));
    const { res, written } = await post(report({ grants: { family_controls: "missing" } }));
    expect(res.statusCode).toBe(202);
    expect(written.capabilities).toMatchObject({ grants: { family_controls: "missing" }, groups: [group()] });
  });

  it("an iPhone upload that carries profiles but not groups keeps the stored groups", async () => {
    withStored(report({ groups: [group()] }));
    const { res, written } = await post(report({ profiles: { others: 0, kinds: [] } }));
    expect(res.statusCode).toBe(202);
    expect(written.capabilities).toMatchObject({ profiles: { others: 0, kinds: [] }, groups: [group()] });
  });

  it("an upload that carries groups stores them", async () => {
    withStored(report({ groups: [group()] }));
    const { written } = await post(report({ groups: [group({ id: ID_B, label: "School", apps: 2 })] }));
    expect(written.capabilities).toMatchObject({ groups: [group({ id: ID_B, label: "School", apps: 2 })] });
  });
});
