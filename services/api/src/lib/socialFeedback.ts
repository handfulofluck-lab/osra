import { prisma } from "../db.js";

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
  const rows = await prisma.socialEventFeedback.groupBy({
    by: ["lang", "topCategory", "modelVersion", "path", "verdict"],
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
