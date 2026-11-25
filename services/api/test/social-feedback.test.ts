import { existsSync, readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { eraseFamilyData } from "../src/lib/accountDeletion.js";
import { applyRetention, eraseChildData } from "../src/lib/usageModel.js";
import { MockRedis, prismaMock, resetPrismaMock } from "./helpers.js";

vi.mock("../src/db.js", async () => {
  const { prismaMock } = await import("./helpers.js");
  return { prisma: prismaMock };
});
vi.mock("ioredis", async () => {
  const { MockRedis } = await import("./helpers.js");
  return { Redis: MockRedis };
});

const schemaPath = fileURLToPath(new URL("../prisma/schema.prisma", import.meta.url));
const migrationPath = fileURLToPath(new URL("../prisma/migrations/0043_social_event_feedback/migration.sql", import.meta.url));
const schema = readFileSync(schemaPath, "utf8");
const migration = existsSync(migrationPath) ? readFileSync(migrationPath, "utf8") : "";
const apiWorkflow = readFileSync(fileURLToPath(new URL("../../../.github/workflows/api.yml", import.meta.url)), "utf8");
const feedbackModel = schema.match(/model SocialEventFeedback \{([\s\S]*?)\n\}/)?.[1] ?? "";
const socialEventModel = schema.match(/model SocialEvent \{([\s\S]*?)\n\}/)?.[1] ?? "";

function mockEmptyRetention() {
  for (const model of ["activityEvent", "webVisit", "socialEvent", "locationPing", "appUsageDaily", "alert"] as const) {
    prismaMock[model].deleteMany.mockResolvedValue({ count: 0 });
  }
  prismaMock.alert.findMany.mockResolvedValue([]);
}

beforeEach(() => {
  resetPrismaMock();
  const redis = new MockRedis();
  redis.publish.mockResolvedValue(0);
});

describe("social feedback CI database provisioning (#1065)", () => {
  it("provisions the dedicated feedback database required by the integration suite", () => {
    expect(apiWorkflow).toContain('OSRA_REQUIRE_DATABASE_TESTS: "1"');
    expect(apiWorkflow).toContain("OSRA_FEEDBACK_DATABASE_URL: postgres://postgres@127.0.0.1:5432/osra_feedback_1065");
    expect(apiWorkflow).toMatch(/CREATE DATABASE osra_feedback_1065/);
  });
});

describe("social feedback storage and deletion (#1065)", () => {
  it("stores one current vote per parent and event with all nullable flag-time fields", () => {
    expect(feedbackModel).toContain("@@unique([socialEventId, parentId])");
    for (const field of ["verdict", "firstVotedAt", "lastChangedAt", "changeCount"]) {
      expect(feedbackModel).toMatch(new RegExp(`\\b${field}\\b`));
    }
    expect(feedbackModel).not.toMatch(/\bparentName\b/);
    for (const field of ["modelVersion", "lang", "topCategory", "topScore", "cutoff", "path", "severity"]) {
      expect(feedbackModel).toMatch(new RegExp(`\\b${field}\\s+\\w+\\?`));
    }
    for (const field of ["modelVersion", "lang", "topCategory", "topScore", "cutoff", "path"]) {
      expect(socialEventModel).toMatch(new RegExp(`\\b${field}\\s+\\w+\\?`));
    }
    expect(socialEventModel).toMatch(/\bseverity\s+String\b/);
  });

  it("deletes only already-orphaned events before adding the child foreign key", () => {
    expect(migration).not.toContain("SocialEventOrphan");
    expect(migration.indexOf('DELETE FROM "SocialEvent"')).toBeLessThan(migration.indexOf('ADD CONSTRAINT "SocialEvent_childId_fkey"'));
    expect(migration).toContain('WHERE NOT EXISTS (SELECT 1 FROM "Child" AS child WHERE child."id" = event."childId")');
    expect(migration).toContain("RAISE NOTICE '0043 deleted % orphaned SocialEvent rows (count only)', orphanCount");
    expect(migration).toContain("SELECT count(*) INTO orphanCount");
  });

  it("deletes a vote with its message through database cascades", () => {
    expect(feedbackModel).toMatch(/socialEvent\s+SocialEvent\s+@relation\(fields: \[socialEventId\], references: \[id\], onDelete: Cascade\)/);
    expect(feedbackModel).toMatch(/parent\s+Parent\s+@relation\(fields: \[parentId\], references: \[id\], onDelete: Cascade\)/);
    expect(migration).toMatch(/FOREIGN KEY \("socialEventId"\) REFERENCES "SocialEvent"\("id"\) ON DELETE CASCADE/);
    expect(migration).toMatch(/FOREIGN KEY \("parentId"\) REFERENCES "Parent"\("id"\) ON DELETE CASCADE/);
  });

  it("deletes votes on the existing child-erasure path through their social events", async () => {
    prismaMock.device.findMany.mockResolvedValue([]);
    prismaMock.socialEvent.deleteMany.mockResolvedValue({ count: 1 });
    await eraseChildData("child-1", 60);
    expect(prismaMock.socialEvent.deleteMany).toHaveBeenCalledWith({ where: { childId: "child-1" } });
    expect(feedbackModel).toContain("onDelete: Cascade");
  });

  it("deletes a family's parent votes explicitly while message deletion cascades the rest", async () => {
    prismaMock.parent.findMany.mockResolvedValue([{ id: "parent-1" }, { id: "parent-2" }]);
    prismaMock.child.findMany.mockResolvedValue([]);
    await eraseFamilyData("fam-1");
    expect(prismaMock.socialEventFeedback.deleteMany).toHaveBeenCalledWith({ where: { parentId: { in: ["parent-1", "parent-2"] } } });
    expect(feedbackModel).toContain("onDelete: Cascade");
  });

  it("deletes expired votes through the existing social-event retention cascade", async () => {
    mockEmptyRetention();
    const now = new Date("2026-11-24T00:00:00.000Z");
    await applyRetention(now, { RETENTION_DAYS: "90" } as NodeJS.ProcessEnv);
    expect(prismaMock.socialEvent.deleteMany).toHaveBeenCalledWith({
      where: { createdAt: { lt: new Date("2026-08-26T00:00:00.000Z") } },
    });
    expect(feedbackModel).toMatch(/socialEvent\s+SocialEvent\s+@relation\([^\n]+onDelete: Cascade\)/);
  });
});

describe("counts-only social feedback aggregation (#1065)", () => {
  it("suppresses buckets below five and excludes a withdrawn current vote on the next run", async () => {
    const { aggregateSocialEventFeedback } = await import("../src/lib/socialFeedback.js");
    const dimensions = { lang: "ar", topCategory: "self_harm", modelVersion: "v9b", path: "own" };
    prismaMock.$queryRaw.mockResolvedValue([{ childId: "child-1", region: "EU" }]);
    prismaMock.consentRecord.findFirst.mockResolvedValue({
      id: "consent-1", childId: "child-1", parentId: "parent-1", method: "sms_plus", jurisdiction: "EU",
      grantedAt: new Date("2026-01-01T00:00:00Z"), expiresAt: null, revokedAt: null, thirdPartySharing: false,
    });
    prismaMock.socialEventFeedback.groupBy.mockResolvedValue([
      { ...dimensions, verdict: "concerning", _count: { _all: 5 } },
      { ...dimensions, verdict: "not_concerning", _count: { _all: 1 } },
      { ...dimensions, lang: "fr", verdict: "concerning", _count: { _all: 4 } },
    ]);

    await expect(aggregateSocialEventFeedback()).resolves.toEqual([
      { ...dimensions, concerning: 5, notConcerning: 1, total: 6 },
    ]);
    expect(prismaMock.socialEventFeedback.groupBy).toHaveBeenCalledWith({
      by: ["lang", "topCategory", "modelVersion", "path", "verdict"],
      where: { socialEvent: { childId: { in: ["child-1"] } } },
      _count: { _all: true },
    });

    // DELETE removes the row, so the next grouped read has only four current votes and emits nothing.
    prismaMock.socialEventFeedback.groupBy.mockResolvedValue([
      { ...dimensions, verdict: "concerning", _count: { _all: 4 } },
    ]);
    await expect(aggregateSocialEventFeedback()).resolves.toEqual([]);
  });
});
