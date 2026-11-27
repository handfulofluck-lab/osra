import { beforeEach, describe, expect, it, vi } from "vitest";
import { rulesRoutes } from "../src/routes/rules.js";
import { DEFAULT_RULESET, defaultRuleSetRow } from "../src/lib/defaultRules.js";
import { agentBedtime, toApiRuleSet } from "../src/lib/ruleSync.js";
import { authHeader, buildApp, deviceHeader, prismaMock, resetPrismaMock } from "./helpers.js";

vi.mock("../src/db.js", async () => {
  const { prismaMock } = await import("./helpers.js");
  return { prisma: prismaMock };
});
vi.mock("ioredis", async () => {
  const { MockRedis } = await import("./helpers.js");
  return { Redis: MockRedis };
});

const CHILD_ID = "child-1";

function row(overrides: Record<string, unknown> = {}) {
  return {
    id: "rs-1",
    childId: CHILD_ID,
    dailyLimitMinutes: 180,
    weekendLimitMinutes: 300,
    bedtimeStart: "21:00",
    bedtimeEnd: "07:00",
    bedtimeEnabled: true,
    schoolHoursStart: "08:00",
    schoolHoursEnd: "15:00",
    schoolDays: [1, 2, 3, 4, 5],
    blockedCategories: ["pornography"],
    allowedDomains: [],
    blockedDomains: [],
    safeSearchEnforced: true,
    appRules: [],
    routines: [],
    updatedAt: "2026-11-26T00:00:00.000Z",
    ...overrides,
  };
}

/**
 * #1172 (Ahmed): a new child got School hours (08:00-15:00, Mon-Fri) and Bedtime (21:00-07:00) switched on
 * before the parent chose anything, and School hours blocked the owner's phone in the middle of setup.
 * No routine may run until a parent turns it on; existing children keep what they have.
 */
describe("#1172 routines start off", () => {
  beforeEach(() => resetPrismaMock());

  it("a new child's defaults have Bedtime off and no school days", () => {
    expect(DEFAULT_RULESET.screenTime.bedtimeEnabled).toBe(false);
    expect(DEFAULT_RULESET.screenTime.schoolHours.days).toEqual([]);
    const created = defaultRuleSetRow("child-new");
    expect(created.bedtimeEnabled).toBe(false);
    expect(created.schoolDays).toEqual([]);
    // The times stay as the suggestion a parent turns on.
    expect(created.bedtimeStart).toBe("21:00");
    expect(created.bedtimeEnd).toBe("07:00");
  });

  it("a row from before the column reads Bedtime on, so existing children keep it", () => {
    const { bedtimeEnabled: _omit, ...legacy } = row();
    expect(toApiRuleSet(legacy).screenTime.bedtimeEnabled).toBe(true);
    expect(toApiRuleSet(row({ bedtimeEnabled: false })).screenTime.bedtimeEnabled).toBe(false);
  });

  it("an agent gets blank bedtime times when Bedtime is off; the parent keeps the stored times", () => {
    const api = toApiRuleSet(row({ bedtimeEnabled: false }));
    const agent = agentBedtime(api);
    expect(agent.screenTime).toMatchObject({ bedtimeStart: "", bedtimeEnd: "", bedtimeEnabled: false });
    expect(api.screenTime.bedtimeStart).toBe("21:00");
    // Bedtime on: untouched.
    const on = toApiRuleSet(row());
    expect(agentBedtime(on)).toBe(on);
  });

  it("a device reading a new child's default rules gets no bedtime and no school days", async () => {
    const app = await buildApp(rulesRoutes, "/v1/rules");
    prismaMock.child.findUnique.mockResolvedValue({ id: CHILD_ID, familyId: "fam-1" });
    prismaMock.ruleSet.findUnique.mockResolvedValue(row({ bedtimeEnabled: false, schoolDays: [] }));
    const res = await app.inject({ method: "GET", url: `/v1/rules/${CHILD_ID}`, headers: deviceHeader(app) });
    expect(res.statusCode).toBe(200);
    const st = res.json().screenTime;
    expect(st.bedtimeStart).toBe("");
    expect(st.bedtimeEnd).toBe("");
    expect(st.schoolHours.days).toEqual([]);
    await app.close();
  });

  it("a parent reading the same rules sees the stored times and the switch off", async () => {
    const app = await buildApp(rulesRoutes, "/v1/rules");
    prismaMock.child.findUnique.mockResolvedValue({ id: CHILD_ID, familyId: "fam-1" });
    prismaMock.ruleSet.findUnique.mockResolvedValue(row({ bedtimeEnabled: false }));
    const res = await app.inject({ method: "GET", url: `/v1/rules/${CHILD_ID}`, headers: authHeader(app) });
    expect(res.statusCode).toBe(200);
    expect(res.json().screenTime).toMatchObject({ bedtimeStart: "21:00", bedtimeEnd: "07:00", bedtimeEnabled: false });
    await app.close();
  });

  function upsertEcho() {
    prismaMock.ruleSet.upsert.mockImplementation(async ({ create }: { create: Record<string, unknown> }) => ({
      id: "rs-1",
      updatedAt: "2026-11-26T00:00:00.000Z",
      ...create,
    }));
    prismaMock.device.findMany.mockResolvedValue([]);
  }

  it("PATCH turns Bedtime on and off and keeps it through unrelated patches", async () => {
    const app = await buildApp(rulesRoutes, "/v1/rules");
    prismaMock.child.findUnique.mockResolvedValue({ id: CHILD_ID, familyId: "fam-1" });
    prismaMock.ruleSet.findUnique.mockResolvedValue(row({ bedtimeEnabled: false, schoolDays: [] }));
    upsertEcho();

    const on = await app.inject({
      method: "PATCH",
      url: `/v1/rules/${CHILD_ID}`,
      headers: authHeader(app),
      payload: { screenTime: { bedtimeEnabled: true } },
    });
    expect(on.statusCode).toBe(200);
    expect(prismaMock.ruleSet.upsert.mock.calls.at(-1)?.[0].update.bedtimeEnabled).toBe(true);

    const other = await app.inject({
      method: "PATCH",
      url: `/v1/rules/${CHILD_ID}`,
      headers: authHeader(app),
      payload: { screenTime: { dailyLimitMinutes: 120 } },
    });
    expect(other.statusCode).toBe(200);
    // The stored value (off) is carried, never reset to on by a patch that didn't mention it.
    expect(prismaMock.ruleSet.upsert.mock.calls.at(-1)?.[0].update.bedtimeEnabled).toBe(false);
    await app.close();
  });

  it("a PUT from an older parent app without the field leaves the stored switch alone", async () => {
    const app = await buildApp(rulesRoutes, "/v1/rules");
    prismaMock.child.findUnique.mockResolvedValue({ id: CHILD_ID, familyId: "fam-1" });
    upsertEcho();
    const res = await app.inject({
      method: "PUT",
      url: `/v1/rules/${CHILD_ID}`,
      headers: authHeader(app),
      payload: {
        screenTime: {
          dailyLimitMinutes: 180,
          weekendLimitMinutes: 300,
          bedtimeStart: "21:00",
          bedtimeEnd: "07:00",
          schoolHours: { start: "08:00", end: "15:00", days: [] },
        },
        webFilter: { blockedCategories: [], allowedDomains: [], blockedDomains: [], safeSearchEnforced: true },
        appRules: [],
        routines: [],
      },
    });
    expect(res.statusCode).toBe(200);
    expect(prismaMock.ruleSet.upsert.mock.calls.at(-1)?.[0].update).not.toHaveProperty("bedtimeEnabled");
    await app.close();
  });

  it("a Bedtime that is off never collides with School hours", async () => {
    const app = await buildApp(rulesRoutes, "/v1/rules");
    prismaMock.child.findUnique.mockResolvedValue({ id: CHILD_ID, familyId: "fam-1" });
    // Stored bedtime 09:00-10:00 would overlap 08:00-15:00 school hours, but it is off.
    prismaMock.ruleSet.findUnique.mockResolvedValue(
      row({ bedtimeStart: "09:00", bedtimeEnd: "10:00", bedtimeEnabled: false, schoolDays: [] }),
    );
    upsertEcho();
    const res = await app.inject({
      method: "PATCH",
      url: `/v1/rules/${CHILD_ID}`,
      headers: authHeader(app),
      payload: { screenTime: { schoolHours: { start: "08:00", end: "15:00", days: [1, 2, 3, 4, 5] } } },
    });
    expect(res.statusCode).toBe(200);

    // Turning that Bedtime on is checked, and refused.
    const clash = await app.inject({
      method: "PATCH",
      url: `/v1/rules/${CHILD_ID}`,
      headers: authHeader(app),
      payload: {
        screenTime: { bedtimeEnabled: true, schoolHours: { start: "08:00", end: "15:00", days: [1, 2, 3, 4, 5] } },
      },
    });
    expect(clash.statusCode).toBe(400);
    expect(clash.json().error).toBe("schedule_overlap");
    await app.close();
  });
});
