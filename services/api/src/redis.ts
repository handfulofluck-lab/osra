import { Redis } from "ioredis";

let publisher: Redis | null = null;

/** Return the shared lazy Redis publisher, creating it on first use (import-safe for tests). */
export function getRedis(): Redis {
  if (!publisher) {
    publisher = new Redis(process.env.REDIS_URL ?? "redis://localhost:6379", {
      maxRetriesPerRequest: 2,
    });
    publisher.on("error", () => {
      /* connection errors are logged by ioredis; publishing is best-effort */
    });
  }
  return publisher;
}

/** Publish a JSON-serialized object to a Redis channel. */
export async function publishJson(channel: string, obj: unknown): Promise<void> {
  await getRedis().publish(channel, JSON.stringify(obj));
}

/** Read and JSON-parse a Redis key, returning null when absent. */
export async function getJson<T = unknown>(key: string): Promise<T | null> {
  const raw = await getRedis().get(key);
  return raw ? (JSON.parse(raw) as T) : null;
}

/** JSON-serialize and store a Redis key, optionally with a TTL in seconds. */
export async function setJson(key: string, obj: unknown, ttlSeconds?: number): Promise<void> {
  const raw = JSON.stringify(obj);
  if (ttlSeconds) await getRedis().set(key, raw, "EX", ttlSeconds);
  else await getRedis().set(key, raw);
}

/** JSON-serialize and store a key with a TTL only when absent (SET NX EX); true when stored. */
export async function setJsonNx(key: string, obj: unknown, ttlSeconds: number): Promise<boolean> {
  const res = await getRedis().set(key, JSON.stringify(obj), "EX", ttlSeconds, "NX");
  return res === "OK";
}
