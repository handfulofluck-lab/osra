import { randomUUID } from "node:crypto";
import type { PrismaClient, SocialEventFeedback } from "@prisma/client";
import { prisma } from "../db.js";
import { checkActiveConsent } from "./consent.js";

export const SOCIAL_FEEDBACK_MIN_BUCKET = 5;

type Bucket = {
  lang: string | null;
  topCategory: string | null;
  modelVersion: string | null;
  path: string | null;
  concerning: number;
  notConcerning: number;
  total: number;
};

export async function aggregateSocialEventFeedback(): Promise<Bucket[]> {
  // This query only finds candidates; it makes no consent decision of its own. Every child goes
  // through the same jurisdiction/revocation/expiry gate as processing, evaluated at export time.
  const candidates = await prisma.$queryRaw<Array<{ childId: string; region: string }>>`
    SELECT DISTINCT event."childId", family."region"::text AS "region"
    FROM "SocialEventFeedback" AS feedback
    JOIN "SocialEvent" AS event ON event."id" = feedback."socialEventId"
    JOIN "Child" AS child ON child."id" = event."childId"
    JOIN "Family" AS family ON family."id" = child."familyId"
  `;
  const allowedChildIds: string[] = [];
  for (const candidate of candidates) {
    const consent = await checkActiveConsent(candidate.childId, candidate.region);
    if (consent.active) allowedChildIds.push(candidate.childId);
  }
  if (allowedChildIds.length === 0) return [];

  const rows = await prisma.socialEventFeedback.groupBy({
    by: ["lang", "topCategory", "modelVersion", "path", "verdict"],
    where: { socialEvent: { childId: { in: allowedChildIds } } },
    _count: { _all: true },
  });
  const buckets = new Map<string, Bucket>();
  for (const row of rows) {
    if (row.verdict !== "concerning" && row.verdict !== "not_concerning") continue;
    const dimensions = {
      lang: row.lang,
      topCategory: row.topCategory,
      modelVersion: row.modelVersion,
      path: row.path,
    };
    const key = JSON.stringify(dimensions);
    const bucket = buckets.get(key) ?? { ...dimensions, concerning: 0, notConcerning: 0, total: 0 };
    const count = row._count._all;
    if (row.verdict === "concerning") bucket.concerning += count;
    else bucket.notConcerning += count;
    bucket.total += count;
    buckets.set(key, bucket);
  }
  return [...buckets.values()]
    .filter((bucket) => bucket.total >= SOCIAL_FEEDBACK_MIN_BUCKET)
    .sort((a, b) => JSON.stringify(a).localeCompare(JSON.stringify(b)));
}

export type SocialEventFeedbackWrite = {
  socialEventId: string;
  parentId: string;
  verdict: "concerning" | "not_concerning";
  modelVersion: string | null;
  lang: string | null;
  topCategory: string | null;
  topScore: number | null;
  cutoff: number | null;
  path: string | null;
  severity: string | null;
};

export async function writeSocialEventFeedback(
  data: SocialEventFeedbackWrite,
  client: PrismaClient = prisma,
): Promise<SocialEventFeedback> {
  const now = new Date();
  const rows = await client.$queryRaw<SocialEventFeedback[]>`
    INSERT INTO "SocialEventFeedback" (
      "id", "socialEventId", "parentId", "verdict", "firstVotedAt", "lastChangedAt", "changeCount",
      "modelVersion", "lang", "topCategory", "topScore", "cutoff", "path", "severity"
    ) VALUES (
      ${randomUUID()}, ${data.socialEventId}, ${data.parentId}, ${data.verdict}, ${now}, ${now}, 0,
      ${data.modelVersion}, ${data.lang}, ${data.topCategory}, ${data.topScore}, ${data.cutoff}, ${data.path}, ${data.severity}
    )
    ON CONFLICT ("socialEventId", "parentId") DO UPDATE SET
      "verdict" = EXCLUDED."verdict",
      "lastChangedAt" = EXCLUDED."lastChangedAt",
      "changeCount" = "SocialEventFeedback"."changeCount" + 1
    WHERE "SocialEventFeedback"."verdict" <> EXCLUDED."verdict"
    RETURNING *
  `;
  if (rows[0]) return rows[0];
  return client.socialEventFeedback.findUniqueOrThrow({
    where: { socialEventId_parentId: { socialEventId: data.socialEventId, parentId: data.parentId } },
  });
}
