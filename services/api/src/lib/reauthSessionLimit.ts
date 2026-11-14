import type { Redis } from "ioredis";

const failureKey = (jti: string) => `auth:reauth:fail:${jti}`;

export async function registerReauthFailure(redis: Redis, jti: string, ttlSeconds: number): Promise<number> {
  if (!Number.isSafeInteger(ttlSeconds) || ttlSeconds <= 0) {
    throw new RangeError("reauthentication failure counter requires a positive TTL");
  }
  const key = failureKey(jti);
  const result = await redis.multi().incr(key).expire(key, ttlSeconds).exec();
  const first = result?.[0];
  const count = Array.isArray(first) ? Number(first[1]) : Number(first);
  if (!Number.isFinite(count)) throw new Error("reauthentication failure counter returned no count");
  return count;
}

export async function removeReauthRefreshRecords(redis: Redis, parentId: string, jti: string): Promise<void> {
  const indexKey = `refresh:index:${parentId}`;
  const hashes = await redis.smembers(indexKey);
  for (const hash of hashes) {
    const raw = await redis.get(`refresh:${hash}`);
    if (!raw) continue;
    let record: { jti?: string | null };
    try {
      record = JSON.parse(raw) as { jti?: string | null };
    } catch {
      continue;
    }
    if (record.jti !== jti) continue;
    await redis.del(`refresh:${hash}`, `refresh:jwt:${hash}`);
    await redis.srem(indexKey, hash);
  }
}
