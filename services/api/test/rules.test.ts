import { beforeEach, describe, expect, it, vi } from "vitest";
import { rulesRoutes } from "../src/routes/rules.js";
import { MockRedis, authHeader, buildApp, deviceHeader, prismaMock, resetPrismaMock } from "./helpers.js";

vi.mock("../src/db.js", async () => {
  const { prismaMock } = await import("./helpers.js");
  return { prisma: prismaMock };
});
vi.mock("ioredis", async () => {
  const { MockRedis } = await import("./helpers.js");
  return { Redis: MockRedis };
});

const CHILD_ID = "child-1";

const validRuleSet = {
  screenTime: {
    dailyLimitMinutes: 180,
    weekendLimitMinutes: 300,
    bedtimeStart: "21:00",
    bedtimeEnd: "07:00",
    schoolHours: { start: "08:00", end: "15:00", days: [1, 2, 3, 4, 5] },
  },
  webFilter: {
    blockedCategories: ["pornography"],
    allowedDomains: [],
    blockedDomains: ["example.com"],
    safeSearchEnforced: true,
  },
  appRules: [{ packageId: "com.game", appName: "Game", action: "block" }],
  routines: [],
};

describe("rules routes", () => {
  beforeEach(() => {
    resetPrismaMock();
  });

  it("rejects an invalid ruleset payload with 400", async () => {
    const app = await buildApp(rulesRoutes, "/v1/rules");
    prismaMock.child.findUnique.mockResolvedValue({ id: CHILD_ID, familyId: "fam-1" });
    const res = await app.inject({
      method: "PUT",
      url: `/v1/rules/${CHILD_ID}`,
      headers: authHeader(app),
      payload: { screenTime: { dailyLimitMinutes: "lots" } },
    });
    expect(res.statusCode).toBe(400);
    await app.close();
  });

  it("rejects overlapping bedtime and school windows with 400", async () => {
    const app = await buildApp(rulesRoutes, "/v1/rules");
    prismaMock.child.findUnique.mockResolvedValue({ id: CHILD_ID, familyId: "fam-1" });
    const payload = {
      ...validRuleSet,
      screenTime: {
        ...validRuleSet.screenTime,
        bedtimeStart: "09:00",
        bedtimeEnd: "10:00", // overlaps school hours 08:00-15:00
      },
    };
    const res = await app.inject({
      method: "PUT",
      url: `/v1/rules/${CHILD_ID}`,
      headers: authHeader(app),
      payload,
    });
    expect(res.statusCode).toBe(400);
    expect(res.json().error).toMatch(/overlap/);
    await app.close();
  });

  it("permits the overlap when allowOverlap is set", async () => {
    const app = await buildApp(rulesRoutes, "/v1/rules");
    prismaMock.child.findUnique.mockResolvedValue({ id: CHILD_ID, familyId: "fam-1" });
    prismaMock.ruleSet.upsert.mockResolvedValue({ id: "rs-1", childId: CHILD_ID });
    prismaMock.device.findMany.mockResolvedValue([]);
    const payload = {
      ...validRuleSet,
      screenTime: { ...validRuleSet.screenTime, bedtimeStart: "09:00", bedtimeEnd: "10:00" },
      allowOverlap: true,
    };
    const res = await app.inject({
      method: "PUT",
      url: `/v1/rules/${CHILD_ID}`,
      headers: authHeader(app),
      payload,
    });
    expect(res.statusCode).toBe(200);
    await app.close();
  });

  it("publishes the full ruleset to Redis on a successful write", async () => {
    const app = await buildApp(rulesRoutes, "/v1/rules");
    prismaMock.child.findUnique.mockResolvedValue({ id: CHILD_ID, familyId: "fam-1" });
    prismaMock.ruleSet.upsert.mockResolvedValue({
      id: "rs-1",
      childId: CHILD_ID,
      dailyLimitMinutes: 180,
      weekendLimitMinutes: 300,
      bedtimeStart: "21:00",
      bedtimeEnd: "07:00",
      schoolHoursStart: "08:00",
      schoolHoursEnd: "15:00",
      schoolDays: [1, 2, 3, 4, 5],
      blockedCategories: ["pornography"],
      allowedDomains: [],
      blockedDomains: ["example.com"],
      safeSearchEnforced: true,
      appRules: [],
      routines: [],
      updatedAt: new Date().toISOString(),
    });
    prismaMock.device.findMany.mockResolvedValue([]);

    const res = await app.inject({
      method: "PUT",
      url: `/v1/rules/${CHILD_ID}`,
      headers: authHeader(app),
      payload: validRuleSet,
    });
    expect(res.statusCode).toBe(200);
    const published = MockRedis.instances.some((instance) =>
      instance.publish.mock.calls.some(
        ([channel, message]: [string, string]) =>
          channel === `child:${CHILD_ID}:rules` &&
          JSON.parse(message).screenTime.dailyLimitMinutes === 180,
      ),
    );
    expect(published).toBe(true);
    await app.close();
  });

  it("fans a rules_updated command out to the child's devices", async () => {
    const app = await buildApp(rulesRoutes, "/v1/rules");
    prismaMock.child.findUnique.mockResolvedValue({ id: CHILD_ID, familyId: "fam-1" });
    prismaMock.ruleSet.upsert.mockResolvedValue({ childId: CHILD_ID });
    prismaMock.device.findMany.mockResolvedValue([]);
    prismaMock.device.findMany.mockResolvedValue([{ id: "dev-1" }, { id: "dev-2" }]);

    const res = await app.inject({
      method: "PUT",
      url: `/v1/rules/${CHILD_ID}`,
      headers: authHeader(app),
      payload: validRuleSet,
    });
    expect(res.statusCode).toBe(200);
    // Phase 2b: one durable rules_updated row per device.
    const queued = prismaMock.deviceCommand.create.mock.calls
      .map(([arg]: [{ data: { deviceId: string; type: string } }]) => arg.data)
      .filter((d) => d.type === "rules_updated" && (d.deviceId === "dev-1" || d.deviceId === "dev-2"));
    expect(queued).toHaveLength(2);
    await app.close();
  });

  it("rejects weekday 0 and accepts Sunday=7 (BUG-002 contract: 1..7 only)", async () => {
    const app = await buildApp(rulesRoutes, "/v1/rules");
    prismaMock.child.findUnique.mockResolvedValue({ id: CHILD_ID, familyId: "fam-1" });
    prismaMock.ruleSet.upsert.mockResolvedValue({ childId: CHILD_ID });
    prismaMock.device.findMany.mockResolvedValue([]);

    const withZero = await app.inject({
      method: "PUT",
      url: `/v1/rules/${CHILD_ID}`,
      headers: authHeader(app),
      payload: {
        ...validRuleSet,
        screenTime: { ...validRuleSet.screenTime, schoolHours: { start: "08:00", end: "15:00", days: [0] } },
      },
    });
    expect(withZero.statusCode).toBe(400);

    const withSunday = await app.inject({
      method: "PUT",
      url: `/v1/rules/${CHILD_ID}`,
      headers: authHeader(app),
      payload: {
        ...validRuleSet,
        routines: [{ name: "Weekend", startTime: "10:00", endTime: "12:00", days: [6, 7], blockedApps: [], allowedApps: [] }],
      },
    });
    expect(withSunday.statusCode).toBe(200);
    await app.close();
  });

  it("caps both screen-time limits at a day: 1441 is refused, 1440 is accepted (#505)", async () => {
    const app = await buildApp(rulesRoutes, "/v1/rules");
    prismaMock.child.findUnique.mockResolvedValue({ id: CHILD_ID, familyId: "fam-1" });
    prismaMock.ruleSet.upsert.mockResolvedValue({ childId: CHILD_ID });
    prismaMock.device.findMany.mockResolvedValue([]);
    const put = (screenTime: Record<string, unknown>) =>
      app.inject({
        method: "PUT",
        url: `/v1/rules/${CHILD_ID}`,
        headers: authHeader(app),
        payload: { ...validRuleSet, screenTime: { ...validRuleSet.screenTime, ...screenTime } },
      });
    expect((await put({ dailyLimitMinutes: 1441 })).statusCode).toBe(400);
    expect((await put({ weekendLimitMinutes: 1441 })).statusCode).toBe(400);
    expect((await put({ dailyLimitMinutes: 1440, weekendLimitMinutes: 1440 })).statusCode).toBe(200);
    await app.close();
  });

  it("enforces family isolation (403 for another family's child)", async () => {
    const app = await buildApp(rulesRoutes, "/v1/rules");
    prismaMock.child.findUnique.mockResolvedValue({ id: CHILD_ID, familyId: "fam-2" });
    const res = await app.inject({
      method: "GET",
      url: `/v1/rules/${CHILD_ID}`,
      headers: authHeader(app, "fam-1"),
    });
    expect(res.statusCode).toBe(403);
    await app.close();
  });

  it("rejects impossible clock times in rule windows (400)", async () => {
    const app = await buildApp(rulesRoutes, "/v1/rules");
    prismaMock.child.findUnique.mockResolvedValue({ id: CHILD_ID, familyId: "fam-1" });

    for (const [bedtimeStart, bedtimeEnd] of [
      ["25:00", "07:00"],
      ["21:99", "07:00"],
      ["21:00", "24:00"],
    ]) {
      const res = await app.inject({
        method: "PUT",
        url: `/v1/rules/${CHILD_ID}`,
        headers: authHeader(app),
        payload: {
          ...validRuleSet,
          screenTime: { ...validRuleSet.screenTime, bedtimeStart, bedtimeEnd },
        },
      });
      expect(res.statusCode).toBe(400);
    }
    expect(prismaMock.ruleSet.upsert).not.toHaveBeenCalled();
    await app.close();
  });

  it("returns the stored ruleset in the nested API shape (GET 200)", async () => {
    const app = await buildApp(rulesRoutes, "/v1/rules");
    prismaMock.child.findUnique.mockResolvedValue({ id: CHILD_ID, familyId: "fam-1" });
    prismaMock.ruleSet.findUnique.mockResolvedValue({
      id: "rs-1",
      childId: CHILD_ID,
      dailyLimitMinutes: 120,
      weekendLimitMinutes: 240,
      bedtimeStart: "20:30",
      bedtimeEnd: "06:30",
      schoolHoursStart: "08:30",
      schoolHoursEnd: "14:30",
      schoolDays: [1, 3, 5],
      blockedCategories: ["gambling"],
      allowedDomains: ["khanacademy.org"],
      blockedDomains: [],
      safeSearchEnforced: false,
      appRules: [{ packageId: "com.game", appName: "Game", action: "block" }],
      routines: [],
      updatedAt: "2026-09-15T00:00:00.000Z",
    });

    const res = await app.inject({ method: "GET", url: `/v1/rules/${CHILD_ID}`, headers: authHeader(app) });
    expect(res.statusCode).toBe(200);
    const body = res.json();
    expect(body.id).toBe("rs-1");
    expect(body.screenTime).toEqual({
      dailyLimitMinutes: 120,
      weekendLimitMinutes: 240,
      bedtimeStart: "20:30",
      bedtimeEnd: "06:30",
      schoolHours: { start: "08:30", end: "14:30", days: [1, 3, 5] },
    });
    expect(body.webFilter).toEqual({
      blockedCategories: ["gambling"],
      allowedDomains: ["khanacademy.org"],
      blockedDomains: [],
      safeSearchEnforced: false,
      youtubeRestrictedMode: "strict",
    });
    expect(body.appRules).toHaveLength(1);
    await app.close();
  });

  it("returns 404 for a missing child (GET) and 401 without a token (PUT)", async () => {
    const app = await buildApp(rulesRoutes, "/v1/rules");
    prismaMock.child.findUnique.mockResolvedValue(null);
    const missing = await app.inject({ method: "GET", url: `/v1/rules/${CHILD_ID}`, headers: authHeader(app) });
    expect(missing.statusCode).toBe(404);

    const unauthenticated = await app.inject({
      method: "PUT",
      url: `/v1/rules/${CHILD_ID}`,
      payload: validRuleSet,
    });
    expect(unauthenticated.statusCode).toBe(401);
    expect(prismaMock.ruleSet.upsert).not.toHaveBeenCalled();
    await app.close();
  });

  it("deep-merges a PATCH onto the existing ruleset (200)", async () => {
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
      blockedCategories: ["pornography"],
      allowedDomains: [],
      blockedDomains: ["example.com"],
      safeSearchEnforced: true,
      appRules: [],
      routines: [],
      updatedAt: "2026-09-15T00:00:00.000Z",
    });
    prismaMock.ruleSet.upsert.mockImplementation(async ({ create }: { create: Record<string, unknown> }) => ({
      id: "rs-1",
      updatedAt: "2026-09-15T00:00:00.000Z",
      ...create,
    }));
    prismaMock.device.findMany.mockResolvedValue([]);

    const res = await app.inject({
      method: "PATCH",
      url: `/v1/rules/${CHILD_ID}`,
      headers: authHeader(app),
      payload: { screenTime: { dailyLimitMinutes: 240 } },
    });
    expect(res.statusCode).toBe(200);
    const body = res.json();
    // The patched field wins; everything else is preserved from the stored row.
    expect(body.screenTime.dailyLimitMinutes).toBe(240);
    expect(body.screenTime.weekendLimitMinutes).toBe(300);
    expect(body.screenTime.bedtimeStart).toBe("21:00");
    expect(body.webFilter.blockedCategories).toEqual(["pornography"]);
    await app.close();
  });

  /**
   * Issue #475: the bump is what the parent compares against the device's applied version, so it has to be
   * part of the write statement itself — a separate update would let two parents write at once and leave a
   * saved ruleset whose version never moved.
   */
  it("bumps rulesVersion in the same statement as the write, on PUT and on PATCH", async () => {
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
      blockedCategories: ["pornography"],
      allowedDomains: [],
      blockedDomains: ["example.com"],
      safeSearchEnforced: true,
      appRules: [],
      routines: [],
      rulesVersion: 3,
      updatedAt: "2026-09-15T00:00:00.000Z",
    });
    prismaMock.ruleSet.upsert.mockImplementation(async ({ create }: { create: Record<string, unknown> }) => ({
      id: "rs-1",
      updatedAt: "2026-09-15T00:00:00.000Z",
      rulesVersion: 4,
      ...create,
    }));
    prismaMock.device.findMany.mockResolvedValue([]);

    const put = await app.inject({ method: "PUT", url: `/v1/rules/${CHILD_ID}`, headers: authHeader(app), payload: validRuleSet });
    expect(put.statusCode).toBe(200);
    expect(put.json()).toMatchObject({ rulesVersion: 4 });

    const patch = await app.inject({
      method: "PATCH",
      url: `/v1/rules/${CHILD_ID}`,
      headers: authHeader(app),
      payload: { screenTime: { dailyLimitMinutes: 200 } },
    });
    expect(patch.statusCode).toBe(200);

    for (const call of prismaMock.ruleSet.upsert.mock.calls) {
      expect(call[0].update.rulesVersion).toEqual({ increment: 1 });
    }
    expect(prismaMock.ruleSet.upsert.mock.calls.length).toBeGreaterThanOrEqual(2);
    await app.close();
  });

  it("rejects an invalid PATCH body (400)", async () => {
    const app = await buildApp(rulesRoutes, "/v1/rules");
    prismaMock.child.findUnique.mockResolvedValue({ id: CHILD_ID, familyId: "fam-1" });

    const negative = await app.inject({
      method: "PATCH",
      url: `/v1/rules/${CHILD_ID}`,
      headers: authHeader(app),
      payload: { screenTime: { dailyLimitMinutes: -5 } },
    });
    expect(negative.statusCode).toBe(400);

    const badTime = await app.inject({
      method: "PATCH",
      url: `/v1/rules/${CHILD_ID}`,
      headers: authHeader(app),
      payload: { screenTime: { bedtimeStart: "9pm" } },
    });
    expect(badTime.statusCode).toBe(400);
    expect(prismaMock.ruleSet.upsert).not.toHaveBeenCalled();
    await app.close();
  });

  it("allows a PATCH that does not touch windows on an allowOverlap ruleset (200)", async () => {
    const app = await buildApp(rulesRoutes, "/v1/rules");
    prismaMock.child.findUnique.mockResolvedValue({ id: CHILD_ID, familyId: "fam-1" });
    // Stored ruleset has overlapping bedtime/school windows (created with allowOverlap: true).
    prismaMock.ruleSet.findUnique.mockResolvedValue({
      id: "rs-1",
      childId: CHILD_ID,
      dailyLimitMinutes: 180,
      weekendLimitMinutes: 300,
      bedtimeStart: "09:00",
      bedtimeEnd: "10:00",
      schoolHoursStart: "08:00",
      schoolHoursEnd: "15:00",
      schoolDays: [1, 2, 3, 4, 5],
      blockedCategories: [],
      allowedDomains: [],
      blockedDomains: [],
      safeSearchEnforced: true,
      appRules: [],
      routines: [],
      updatedAt: "2026-09-15T00:00:00.000Z",
    });
    prismaMock.ruleSet.upsert.mockImplementation(async ({ create }: { create: Record<string, unknown> }) => ({
      id: "rs-1",
      updatedAt: "2026-09-15T00:00:00.000Z",
      ...create,
    }));
    prismaMock.device.findMany.mockResolvedValue([]);

    // An unrelated patch (app rules only) must not re-trigger the overlap guard.
    const res = await app.inject({
      method: "PATCH",
      url: `/v1/rules/${CHILD_ID}`,
      headers: authHeader(app),
      payload: { appRules: [{ packageId: "com.game", appName: "Game", action: "block" }] },
    });
    expect(res.statusCode).toBe(200);
    expect(prismaMock.ruleSet.upsert).toHaveBeenCalled();
    await app.close();
  });

  it("still rejects a PATCH that changes windows into an overlap (400)", async () => {
    const app = await buildApp(rulesRoutes, "/v1/rules");
    prismaMock.child.findUnique.mockResolvedValue({ id: CHILD_ID, familyId: "fam-1" });
    prismaMock.ruleSet.findUnique.mockResolvedValue(null); // defaults: no overlap

    const res = await app.inject({
      method: "PATCH",
      url: `/v1/rules/${CHILD_ID}`,
      headers: authHeader(app),
      payload: { screenTime: { bedtimeStart: "09:00", bedtimeEnd: "10:00" } },
    });
    expect(res.statusCode).toBe(400);
    expect(res.json().error).toMatch(/overlap/);
    expect(prismaMock.ruleSet.upsert).not.toHaveBeenCalled();
    await app.close();
  });

  it("persists and round-trips youtubeRestrictedMode (strict, moderate, off) (#45)", async () => {
    const app = await buildApp(rulesRoutes, "/v1/rules");
    prismaMock.child.findUnique.mockResolvedValue({ id: CHILD_ID, familyId: "fam-1" });
    prismaMock.device.findMany.mockResolvedValue([]);

    for (const mode of ["moderate", "off", "strict"] as const) {
      let storedRow: Record<string, unknown> | null = null;
      prismaMock.ruleSet.upsert.mockImplementation(async ({ create }: { create: Record<string, unknown> }) => {
        storedRow = { id: "rs-1", childId: CHILD_ID, ...create, updatedAt: new Date().toISOString() };
        return storedRow;
      });
      prismaMock.ruleSet.findUnique.mockImplementation(async () => storedRow);

      const putRes = await app.inject({
        method: "PUT",
        url: `/v1/rules/${CHILD_ID}`,
        headers: authHeader(app),
        payload: {
          ...validRuleSet,
          webFilter: {
            ...validRuleSet.webFilter,
            youtubeRestrictedMode: mode,
          },
        },
      });
      expect(putRes.statusCode).toBe(200);
      expect(putRes.json().webFilter.youtubeRestrictedMode).toBe(mode);
      expect(prismaMock.ruleSet.upsert).toHaveBeenCalledWith(
        expect.objectContaining({
          create: expect.objectContaining({ youtubeRestrictedMode: mode }),
          update: expect.objectContaining({ youtubeRestrictedMode: mode }),
        }),
      );

      const getRes = await app.inject({
        method: "GET",
        url: `/v1/rules/${CHILD_ID}`,
        headers: authHeader(app),
      });
      expect(getRes.statusCode).toBe(200);
      expect(getRes.json().webFilter.youtubeRestrictedMode).toBe(mode);
    }
    await app.close();
  });
});

describe("device-token child scoping on rules reads", () => {
  beforeEach(() => {
    resetPrismaMock();
  });

  it("lets a device read its own child's rules (200)", async () => {
    const app = await buildApp(rulesRoutes, "/v1/rules");
    prismaMock.child.findUnique.mockResolvedValue({ id: CHILD_ID, familyId: "fam-1" });
    prismaMock.ruleSet.findUnique.mockResolvedValue(null);

    const res = await app.inject({
      method: "GET",
      url: `/v1/rules/${CHILD_ID}`,
      headers: deviceHeader(app),
    });
    expect(res.statusCode).toBe(200);
    await app.close();
  });

  it("forbids a device from reading a sibling child's rules (403 cross_child_forbidden)", async () => {
    const app = await buildApp(rulesRoutes, "/v1/rules");
    prismaMock.child.findUnique.mockResolvedValue({ id: "child-2", familyId: "fam-1" });
    prismaMock.ruleSet.findUnique.mockResolvedValue(null);

    const res = await app.inject({
      method: "GET",
      url: "/v1/rules/child-2",
      headers: deviceHeader(app),
    });
    expect(res.statusCode).toBe(403);
    expect(res.json().error).toBe("cross_child_forbidden");
    expect(prismaMock.ruleSet.findUnique).not.toHaveBeenCalled();
    await app.close();
  });

  it("keeps parent access family-scoped, not child-scoped (200 for a sibling child)", async () => {
    const app = await buildApp(rulesRoutes, "/v1/rules");
    prismaMock.child.findUnique.mockResolvedValue({ id: "child-2", familyId: "fam-1" });
    prismaMock.ruleSet.findUnique.mockResolvedValue(null);

    const res = await app.inject({
      method: "GET",
      url: "/v1/rules/child-2",
      headers: authHeader(app, "fam-1"),
    });
    expect(res.statusCode).toBe(200);
    await app.close();
  });

});
