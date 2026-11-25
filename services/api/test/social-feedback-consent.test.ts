import { existsSync, readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { prismaMock, resetPrismaMock } from "./helpers.js";

vi.mock("../src/db.js", async () => {
  const { prismaMock } = await import("./helpers.js");
  return { prisma: prismaMock };
});

const dimensions = { lang: "ar", topCategory: "self_harm", modelVersion: "v9b", path: "own" };
const groupedVotes = [{ ...dimensions, verdict: "concerning", _count: { _all: 5 } }];
const activeConsent = {
  id: "consent-1", childId: "child-1", parentId: "parent-1", method: "sms_plus",
  jurisdiction: "EU", grantedAt: new Date("2026-01-01T00:00:00Z"), expiresAt: null,
  revokedAt: null, thirdPartySharing: false,
};

beforeEach(() => {
  resetPrismaMock();
  prismaMock.$queryRaw.mockResolvedValue([{ childId: "child-1", region: "EU" }]);
  prismaMock.socialEventFeedback.groupBy.mockResolvedValue(groupedVotes);
  prismaMock.consentRecord.findFirst.mockResolvedValue(activeConsent);
});

describe("consent at social-feedback export time (#1113)", () => {
  it("aggregates only children whose current consent passes the shared gate", async () => {
    const { aggregateSocialEventFeedback } = await import("../src/lib/socialFeedback.js");
    await expect(aggregateSocialEventFeedback()).resolves.toEqual([
      { ...dimensions, concerning: 5, notConcerning: 0, total: 5 },
    ]);
    expect(prismaMock.consentRecord.findFirst).toHaveBeenCalledWith({
      where: {
        childId: "child-1",
        revokedAt: null,
        OR: [{ expiresAt: null }, { expiresAt: { gt: expect.any(Date) } }],
      },
      orderBy: { grantedAt: "desc" },
    });
    expect(prismaMock.socialEventFeedback.groupBy).toHaveBeenCalledWith({
      by: ["lang", "topCategory", "modelVersion", "path", "verdict"],
      where: { socialEvent: { childId: { in: ["child-1"] } } },
      _count: { _all: true },
    });
  });

  it.each([
    ["missing", null],
    ["revoked", null],
    ["expired", null],
    ["wrong-jurisdiction", { ...activeConsent, jurisdiction: "US" }],
  ])("excludes %s consent without reading vote buckets", async (_case, consent) => {
    prismaMock.consentRecord.findFirst.mockResolvedValue(consent);
    const { aggregateSocialEventFeedback } = await import("../src/lib/socialFeedback.js");
    await expect(aggregateSocialEventFeedback()).resolves.toEqual([]);
    expect(prismaMock.socialEventFeedback.groupBy).not.toHaveBeenCalled();
  });

  it("drops a family that revokes after voting from the very next export", async () => {
    const { aggregateSocialEventFeedback } = await import("../src/lib/socialFeedback.js");
    await expect(aggregateSocialEventFeedback()).resolves.toHaveLength(1);

    prismaMock.consentRecord.findFirst.mockResolvedValue(null);
    await expect(aggregateSocialEventFeedback()).resolves.toEqual([]);
    expect(prismaMock.socialEventFeedback.groupBy).toHaveBeenCalledTimes(1);
  });
});

describe("parent-name copy removal (#1113)", () => {
  it("drops the denormalised column with a migration that is safe on an empty table", () => {
    const schema = readFileSync(fileURLToPath(new URL("../prisma/schema.prisma", import.meta.url)), "utf8");
    const feedbackModel = schema.match(/model SocialEventFeedback \{([\s\S]*?)\n\}/)?.[1] ?? "";
    expect(feedbackModel).not.toMatch(/\bparentName\b/);

    const path = fileURLToPath(new URL("../prisma/migrations/0044_drop_social_feedback_parent_name/migration.sql", import.meta.url));
    expect(existsSync(path)).toBe(true);
    const migration = existsSync(path) ? readFileSync(path, "utf8") : "";
    expect(migration).toContain('ALTER TABLE "SocialEventFeedback" DROP COLUMN "parentName"');
    expect(migration).not.toContain("CREATE TABLE");
    expect(migration).toContain("rollback restores the column but not old values");
  });
});
