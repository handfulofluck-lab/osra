import { beforeEach, describe, expect, it, vi } from "vitest";
import { rulesRoutes } from "../src/routes/rules.js";
import { toApiRuleSet } from "../src/lib/ruleSync.js";
import { authHeader, buildApp, prismaMock, resetPrismaMock } from "./helpers.js";

vi.mock("../src/db.js", async () => {
  const { prismaMock } = await import("./helpers.js");
  return { prisma: prismaMock };
});
vi.mock("ioredis", async () => {
  const { MockRedis } = await import("./helpers.js");
  return { Redis: MockRedis };
});

/**
 * ADR-0037 PR B3: rules on iPhone app groups. The parent blocks a group by the id the phone reported; the server
 * stores `{groupId, action: "block"}` only, never anything about what the group holds.
 */
const CHILD_ID = "child-1";
const G1 = "6f1c2b8e-3d4a-4e5f-9a0b-1c2d3e4f5a6b";
const G2 = "0e9d8c7b-6a5f-4e3d-8c2b-1a0f9e8d7c6b";

const base = {
  screenTime: {
    dailyLimitMinutes: 180,
    weekendLimitMinutes: 300,
    bedtimeStart: "21:00",
    bedtimeEnd: "07:00",
    schoolHours: { start: "08:00", end: "15:00", days: [1, 2, 3, 4, 5] },
  },
  webFilter: { blockedCategories: [], allowedDomains: [], blockedDomains: [], safeSearchEnforced: true },
  appRules: [],
  routines: [],
};

async function put(payload: unknown) {
  const app = await buildApp(rulesRoutes, "/v1/rules");
  prismaMock.child.findUnique.mockResolvedValue({ id: CHILD_ID, familyId: "fam-1" });
  prismaMock.ruleSet.upsert.mockImplementation(async (args: { create: Record<string, unknown> }) => ({
    id: "rs-1",
    ...args.create,
  }));
  prismaMock.device.findMany.mockResolvedValue([]);
  const res = await app.inject({ method: "PUT", url: `/v1/rules/${CHILD_ID}`, headers: authHeader(app), payload });
  await app.close();
  return res;
}

describe("app group rules (ADR-0037 B3)", () => {
  beforeEach(() => resetPrismaMock());

  it("stores and returns a block by group id", async () => {
    const res = await put({ ...base, appGroupRules: [{ groupId: G1, action: "block" }] });
    expect(res.statusCode).toBe(200);
    expect(res.json().appGroupRules).toEqual([{ groupId: G1, action: "block" }]);
    const write = prismaMock.ruleSet.upsert.mock.calls[0][0] as { create: Record<string, unknown> };
    expect(write.create.appGroupRules).toEqual([{ groupId: G1, action: "block" }]);
  });

  it("a ruleset without the field stores none", async () => {
    const res = await put(base);
    expect(res.statusCode).toBe(200);
    expect(res.json().appGroupRules).toEqual([]);
  });

  it.each([
    ["an id that is not a UUID", [{ groupId: "games", action: "block" }]],
    ["an action other than block", [{ groupId: G1, action: "allow" }]],
    ["a time limit, which is PR C", [{ groupId: G1, action: "block", dailyLimitMinutes: 30 }]],
    ["two rules for one group, in any case", [{ groupId: G1, action: "block" }, { groupId: G1.toUpperCase(), action: "block" }]],
    ["a label or app names, which the server never holds", [{ groupId: G1, action: "block", label: "Games" }]],
  ])("refuses %s", async (_name, appGroupRules) => {
    const res = await put({ ...base, appGroupRules });
    expect(res.statusCode).toBe(400);
    expect(prismaMock.ruleSet.upsert).not.toHaveBeenCalled();
  });

  it("refuses more rules than a phone can have groups", async () => {
    const many = Array.from({ length: 21 }, (_, i) => ({
      groupId: `00000000-0000-4000-8000-${String(i).padStart(12, "0")}`,
      action: "block",
    }));
    expect((await put({ ...base, appGroupRules: many.slice(0, 20) })).statusCode).toBe(200);
    resetPrismaMock();
    expect((await put({ ...base, appGroupRules: many })).statusCode).toBe(400);
  });

  it("a PATCH without the field keeps the stored rules, and with it replaces them", async () => {
    const app = await buildApp(rulesRoutes, "/v1/rules");
    prismaMock.child.findUnique.mockResolvedValue({ id: CHILD_ID, familyId: "fam-1" });
    prismaMock.ruleSet.findUnique.mockResolvedValue({
      id: "rs-1",
      childId: CHILD_ID,
      dailyLimitMinutes: 180,
      weekendLimitMinutes: 300,
      bedtimeStart: "21:00",
      bedtimeEnd: "07:00",
      schoolHoursStart: "08:00",
      schoolHoursEnd: "15:00",
      schoolDays: [1, 2, 3, 4, 5],
      blockedCategories: [],
      allowedDomains: [],
      blockedDomains: [],
      safeSearchEnforced: true,
      appRules: [],
      routines: [],
      appGroupRules: [{ groupId: G1, action: "block" }],
      alwaysAllowedApps: [],
      socialMonitoring: {},
      contactAllowlist: [],
    });
    prismaMock.ruleSet.upsert.mockImplementation(async (args: { create: Record<string, unknown> }) => ({ id: "rs-1", ...args.create }));
    prismaMock.device.findMany.mockResolvedValue([]);
    const keep = await app.inject({
      method: "PATCH",
      url: `/v1/rules/${CHILD_ID}`,
      headers: authHeader(app),
      payload: { screenTime: { dailyLimitMinutes: 120 } },
    });
    expect(keep.statusCode).toBe(200);
    expect(keep.json().appGroupRules).toEqual([{ groupId: G1, action: "block" }]);
    const replace = await app.inject({
      method: "PATCH",
      url: `/v1/rules/${CHILD_ID}`,
      headers: authHeader(app),
      payload: { appGroupRules: [{ groupId: G2, action: "block" }] },
    });
    expect(replace.statusCode).toBe(200);
    expect(replace.json().appGroupRules).toEqual([{ groupId: G2, action: "block" }]);
    await app.close();
  });

  it("a ruleset row from before the column reads as no rules", () => {
    expect(toApiRuleSet({ id: "rs-1", childId: CHILD_ID }).appGroupRules).toEqual([]);
  });
});
