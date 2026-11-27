import { beforeEach, describe, expect, it, vi } from "vitest";
import { rulesRoutes } from "../src/routes/rules.js";
import { MockRedis, authHeader, buildApp, prismaMock, resetPrismaMock } from "./helpers.js";

vi.mock("../src/db.js", async () => {
  const { prismaMock } = await import("./helpers.js");
  return { prisma: prismaMock };
});
vi.mock("ioredis", async () => {
  const { MockRedis } = await import("./helpers.js");
  return { Redis: MockRedis };
});

const CHILD_ID = "child-1";

function payload(days: number[]) {
  return {
    screenTime: {
      dailyLimitMinutes: 180,
      weekendLimitMinutes: 300,
      bedtimeStart: "09:00",
      bedtimeEnd: "10:00",
      schoolHours: { start: "08:00", end: "15:00", days },
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
}

function expectedOverlap(days: number[]) {
  return {
    error: "schedule_overlap",
    windows: {
      bedtime: { start: "09:00", end: "10:00" },
      schoolHours: { start: "08:00", end: "15:00", days },
    },
  };
}

describe("bedtime and school-hours overlap", () => {
  beforeEach(() => resetPrismaMock());

  it("refuses a real weekend collision with the typed overlap", async () => {
    const app = await buildApp(rulesRoutes, "/v1/rules");
    prismaMock.child.findUnique.mockResolvedValue({ id: CHILD_ID, familyId: "fam-1" });

    const res = await app.inject({
      method: "PUT", url: `/v1/rules/${CHILD_ID}`, headers: authHeader(app), payload: payload([6, 7]),
    });

    expect(res.statusCode).toBe(400);
    expect(res.json()).toEqual(expectedOverlap([6, 7]));
    expect(res.body).not.toContain("allowOverlap");
    expect(prismaMock.ruleSet.upsert).not.toHaveBeenCalled();
    await app.close();
  });

  it("accepts an overnight bedtime that does not meet school hours", async () => {
    const app = await buildApp(rulesRoutes, "/v1/rules");
    prismaMock.child.findUnique.mockResolvedValue({ id: CHILD_ID, familyId: "fam-1" });
    prismaMock.ruleSet.upsert.mockResolvedValue({ id: "rs-1", childId: CHILD_ID });
    prismaMock.device.findMany.mockResolvedValue([]);

    const input = payload([1, 2, 3, 4, 5]);
    input.screenTime.bedtimeStart = "21:00";
    input.screenTime.bedtimeEnd = "06:30";
    const res = await app.inject({
      method: "PUT", url: `/v1/rules/${CHILD_ID}`, headers: authHeader(app), payload: input,
    });

    expect(res.statusCode).toBe(200);
    expect(prismaMock.ruleSet.upsert).toHaveBeenCalledOnce();
    await app.close();
  });

  it("returns schedule_overlap with both windows on a shared school day", async () => {
    const app = await buildApp(rulesRoutes, "/v1/rules");
    prismaMock.child.findUnique.mockResolvedValue({ id: CHILD_ID, familyId: "fam-1" });

    const res = await app.inject({
      method: "PUT", url: `/v1/rules/${CHILD_ID}`, headers: authHeader(app), payload: payload([1, 2, 3, 4, 5]),
    });

    expect(res.statusCode).toBe(400);
    expect(res.json()).toEqual(expectedOverlap([1, 2, 3, 4, 5]));
    expect(res.body).not.toContain("allowOverlap");
    expect(prismaMock.ruleSet.upsert).not.toHaveBeenCalled();
    await app.close();
  });

  it("returns the same typed overlap through PATCH", async () => {
    const app = await buildApp(rulesRoutes, "/v1/rules");
    prismaMock.child.findUnique.mockResolvedValue({ id: CHILD_ID, familyId: "fam-1" });

    const res = await app.inject({
      // #1172: with no stored row the defaults have Bedtime off, so this PATCH switches it on to collide.
      method: "PATCH", url: `/v1/rules/${CHILD_ID}`, headers: authHeader(app),
      payload: { ...payload([1, 3, 5]), screenTime: { ...payload([1, 3, 5]).screenTime, bedtimeEnabled: true } },
    });

    expect(res.statusCode).toBe(400);
    expect(res.json()).toEqual(expectedOverlap([1, 3, 5]));
    expect(res.body).not.toContain("allowOverlap");
    expect(prismaMock.ruleSet.upsert).not.toHaveBeenCalled();
    await app.close();
  });

  it("does not invent an overlap when there are no school days", async () => {
    const app = await buildApp(rulesRoutes, "/v1/rules");
    prismaMock.child.findUnique.mockResolvedValue({ id: CHILD_ID, familyId: "fam-1" });
    prismaMock.ruleSet.upsert.mockResolvedValue({ id: "rs-1", childId: CHILD_ID });
    prismaMock.device.findMany.mockResolvedValue([]);

    const res = await app.inject({
      method: "PUT", url: `/v1/rules/${CHILD_ID}`, headers: authHeader(app), payload: payload([]),
    });

    expect(res.statusCode).toBe(200);
    expect(prismaMock.ruleSet.upsert).toHaveBeenCalledOnce();
    await app.close();
  });
});
