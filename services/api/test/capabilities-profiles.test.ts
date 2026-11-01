import { beforeEach, describe, expect, it, vi } from "vitest";
import { CapabilitiesSchema, setupFor, withStoredProfiles } from "../src/lib/capabilities.js";
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
 * osra-security#6 item 2: the capability report says whether the phone has another space (a clone profile,
 * a work profile, an unknown one) — counts and kinds only.
 *
 * Mutants these rows are written against (Claude's list on #6): a missing `profiles` wiping the stored
 * value; `others` above 8 accepted; a duplicate kind accepted; `others > 0` with empty kinds accepted.
 */

const NOW = Date.UTC(2026, 10, 1, 12, 0, 0);
const DEVICE = { id: "dev-1", childId: "child-1", child: { familyId: "fam-1" } };

function report(overrides: Record<string, unknown> = {}) {
  return {
    client: { app: "child-android", version: "0.2.0", build: 2, flavour: "full" },
    grants: { accessibility: "granted" },
    features: { app_blocking: "ready" },
    ...overrides,
  };
}

const ok = (profiles: unknown) => CapabilitiesSchema.safeParse(report({ profiles })).success;

describe("profiles — the shape", () => {
  it("accepts counts with kinds, and a phone with no other space", () => {
    expect(ok({ others: 1, kinds: ["clone"] })).toBe(true);
    expect(ok({ others: 2, kinds: ["clone", "work"] })).toBe(true);
    expect(ok({ others: 2, kinds: ["clone"] })).toBe(true); // two clones are one kind
    expect(ok({ others: 0, kinds: [] })).toBe(true);
    expect(ok({ others: 8, kinds: ["other"] })).toBe(true);
  });

  it("stays optional: a report without it is still valid", () => {
    expect(CapabilitiesSchema.safeParse(report()).success).toBe(true);
  });

  it("refuses more than 8 others", () => {
    expect(ok({ others: 9, kinds: ["other"] })).toBe(false);
    expect(ok({ others: -1, kinds: [] })).toBe(false);
    expect(ok({ others: 1.5, kinds: ["clone"] })).toBe(false);
  });

  it("refuses a repeated kind", () => {
    expect(ok({ others: 2, kinds: ["clone", "clone"] })).toBe(false);
  });

  it("refuses others > 0 with no kind, so an unknown profile cannot read as clean", () => {
    expect(ok({ others: 1, kinds: [] })).toBe(false);
  });

  it("refuses more kinds than others", () => {
    expect(ok({ others: 1, kinds: ["clone", "work"] })).toBe(false);
    expect(ok({ others: 0, kinds: ["other"] })).toBe(false);
  });

  it("refuses an unknown kind, and anything identifying", () => {
    expect(ok({ others: 1, kinds: ["dual_messenger"] })).toBe(false);
    expect(ok({ others: 1, kinds: ["clone"], userIds: [95] })).toBe(false);
    expect(ok({ others: 1, kinds: ["clone"], apps: ["com.whatsapp"] })).toBe(false);
  });
});

describe("profiles — storage and the parent's projection", () => {
  const stored = report({ profiles: { others: 1, kinds: ["clone"] } });

  it("a report without profiles keeps the stored value", () => {
    const next = CapabilitiesSchema.parse(report({ grants: { accessibility: "missing" } }));
    const merged = withStoredProfiles(next, stored);
    expect(merged.profiles).toEqual({ others: 1, kinds: ["clone"] });
    expect(merged.grants).toEqual({ accessibility: "missing" }); // the rest is the new report
  });

  it("a report with profiles replaces the stored value, including back to none", () => {
    const next = CapabilitiesSchema.parse(report({ profiles: { others: 0, kinds: [] } }));
    expect(withStoredProfiles(next, stored).profiles).toEqual({ others: 0, kinds: [] });
  });

  it("nothing stored, or a stored value that no longer parses, carries nothing", () => {
    const next = CapabilitiesSchema.parse(report());
    expect(withStoredProfiles(next, null).profiles).toBeUndefined();
    expect(withStoredProfiles(next, { garbage: true }).profiles).toBeUndefined();
  });

  it("setup shows the profiles, and null when no report carried them", () => {
    const at = new Date(NOW - 60_000);
    expect(setupFor({ capabilities: stored, capabilitiesReportedAt: at }, NOW).profiles).toEqual({
      others: 1,
      kinds: ["clone"],
    });
    expect(setupFor({ capabilities: report(), capabilitiesReportedAt: at }, NOW).profiles).toBeNull();
    expect(setupFor({ capabilities: null, capabilitiesReportedAt: null }, NOW).profiles).toBeNull();
  });
});

describe("profiles — at the telemetry route", () => {
  beforeEach(() => resetPrismaMock());

  function withStored(capabilities: unknown) {
    // The auth middleware and the stored-report read both use findUnique; only the latter selects capabilities.
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

  it("an upload whose report omits profiles keeps the stored profiles", async () => {
    withStored(report({ profiles: { others: 1, kinds: ["clone"] } }));
    const { res, written } = await post(report({ grants: { accessibility: "missing" } }));
    expect(res.statusCode).toBe(202);
    expect(written.capabilities).toMatchObject({
      grants: { accessibility: "missing" },
      profiles: { others: 1, kinds: ["clone"] },
    });
  });

  it("an upload that carries profiles stores them", async () => {
    withStored(report({ profiles: { others: 1, kinds: ["clone"] } }));
    const { res, written } = await post(report({ profiles: { others: 0, kinds: [] } }));
    expect(res.statusCode).toBe(202);
    expect(written.capabilities).toMatchObject({ profiles: { others: 0, kinds: [] } });
  });

  it("a bad profiles block costs the report field, not the upload", async () => {
    withStored(null);
    const { res, written } = await post(report({ profiles: { others: 1, kinds: [] } }));
    expect(res.statusCode).toBe(400);
    expect(res.json().error).toBe("invalid_capabilities");
    expect(written.capabilities).toBeUndefined();
  });
});
