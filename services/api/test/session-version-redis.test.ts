import { randomUUID } from "node:crypto";
import { Redis } from "ioredis";
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import {
  DELETED_SESSION_MARKER,
  SESSION_VERSION_CLEANUP_BELOW_FLOOR_SCRIPT,
  SESSION_VERSION_FLOOR_SCRIPT,
  SESSION_VERSION_MISS_SENTINEL,
  invalidateSessionsBefore,
  isParentSessionLive,
  reconcileSessionVersionCacheAfterCommit,
  revokedTokenKey,
  sessionVersionKey,
} from "../src/lib/sessions.js";
import { prismaMock, resetPrismaMock } from "./helpers.js";

vi.mock("../src/db.js", async () => {
  const { prismaMock } = await import("./helpers.js");
  return { prisma: prismaMock };
});

const redisUrl = process.env.OSRA_TEST_REDIS_URL;

if (process.env.OSRA_REQUIRE_REDIS_TESTS === "1" && !redisUrl) {
  throw new Error("OSRA_TEST_REDIS_URL is required when OSRA_REQUIRE_REDIS_TESTS=1");
}

if (redisUrl) {
  const parsed = new URL(redisUrl);
  if (!["127.0.0.1", "localhost", "::1"].includes(parsed.hostname)) {
    throw new Error("The Redis Lua tests require a loopback Redis instance (127.0.0.1 / localhost / ::1)");
  }
}

const describeRedis = redisUrl ? describe.sequential : describe.skip;

/**
 * Real-Redis Lua execution tests for `SESSION_VERSION_FLOOR_SCRIPT` and
 * `SESSION_VERSION_CLEANUP_BELOW_FLOOR_SCRIPT` (osra-security#92 / PR #1252).
 */
describeRedis("session-version atomic Lua floor and conditional cleanup against real Redis", () => {
  const runPrefix = `osra:test:sv-floor:${randomUUID()}`;
  const touchedKeys = new Set<string>();
  const savedRedisUrl = process.env.REDIS_URL;
  let client: Redis;

  const track = (key: string): string => {
    touchedKeys.add(key);
    return key;
  };

  beforeAll(async () => {
    process.env.REDIS_URL = redisUrl!;
    client = new Redis(redisUrl!, { maxRetriesPerRequest: 2 });
    await client.ping();
    const { closeRedis } = await import("../src/redis.js");
    await closeRedis();
  });

  beforeEach(() => {
    resetPrismaMock();
  });

  afterEach(async () => {
    if (touchedKeys.size > 0) {
      await client.del(...touchedKeys);
      touchedKeys.clear();
    }
  });

  afterAll(async () => {
    const { closeRedis } = await import("../src/redis.js");
    await closeRedis();
    await client.quit();
    if (savedRedisUrl === undefined) delete process.env.REDIS_URL;
    else process.env.REDIS_URL = savedRedisUrl;
  });

  it("SESSION_VERSION_FLOOR_SCRIPT distinguishes warm __MISS__ (no create) from allowCreate=1 and preserves higher/deleted", async () => {
    const key = track(`${runPrefix}:floor`);

    // Warm probe (`ARGV[2] = '0'`) on absent key -> returns `__MISS__` and leaves key absent!
    expect(await client.eval(SESSION_VERSION_FLOOR_SCRIPT, 1, key, "3", "0")).toBe(SESSION_VERSION_MISS_SENTINEL);
    expect(await client.get(key)).toBeNull();

    // Post-restore (`ARGV[2] = '1'`) on absent key -> initializes floor=3 (no TTL)
    expect(await client.eval(SESSION_VERSION_FLOOR_SCRIPT, 1, key, "3", "1")).toBe("3");
    expect(await client.get(key)).toBe("3");
    expect(await client.ttl(key)).toBe(-1);

    // Equal (rebuilt at floor=3) -> stays "3" on warm probe
    expect(await client.eval(SESSION_VERSION_FLOOR_SCRIPT, 1, key, "3", "0")).toBe("3");
    expect(await client.get(key)).toBe("3");

    // Higher (newer generation "6" vs floor=4) -> stays "6"
    await client.set(key, "6");
    expect(await client.eval(SESSION_VERSION_FLOOR_SCRIPT, 1, key, "4", "0")).toBe("6");
    expect(await client.get(key)).toBe("6");

    // Lower ("2" vs floor=5) -> raised to "5"
    await client.set(key, "2");
    expect(await client.eval(SESSION_VERSION_FLOOR_SCRIPT, 1, key, "5", "0")).toBe("5");
    expect(await client.get(key)).toBe("5");

    // Corrupt non-numeric -> reset to floor="4"
    await client.set(key, "not-a-number");
    expect(await client.eval(SESSION_VERSION_FLOOR_SCRIPT, 1, key, "4", "0")).toBe("4");
    expect(await client.get(key)).toBe("4");

    // Deleted tombstone -> preserved untouched
    await client.set(key, DELETED_SESSION_MARKER);
    expect(await client.eval(SESSION_VERSION_FLOOR_SCRIPT, 1, key, "99", "1")).toBe(DELETED_SESSION_MARKER);
    expect(await client.get(key)).toBe(DELETED_SESSION_MARKER);
  });

  it("SESSION_VERSION_CLEANUP_BELOW_FLOOR_SCRIPT deletes stale/corrupt values while preserving deleted and >= floor", async () => {
    const key = track(`${runPrefix}:cleanup`);

    await client.set(key, "2");
    expect(await client.eval(SESSION_VERSION_CLEANUP_BELOW_FLOOR_SCRIPT, 1, key, "4")).toBe(1);
    expect(await client.get(key)).toBeNull();

    await client.set(key, "4");
    expect(await client.eval(SESSION_VERSION_CLEANUP_BELOW_FLOOR_SCRIPT, 1, key, "4")).toBe(0);
    expect(await client.get(key)).toBe("4");

    await client.set(key, "7");
    expect(await client.eval(SESSION_VERSION_CLEANUP_BELOW_FLOOR_SCRIPT, 1, key, "4")).toBe(0);
    expect(await client.get(key)).toBe("7");

    await client.set(key, DELETED_SESSION_MARKER);
    expect(await client.eval(SESSION_VERSION_CLEANUP_BELOW_FLOOR_SCRIPT, 1, key, "99")).toBe(0);
    expect(await client.get(key)).toBe(DELETED_SESSION_MARKER);
  });

  it("keeps absent marker absent when restoration fails and restores durable RevokedToken rows when warm marker vanished", async () => {
    const parentId = `${runPrefix}:parent`;
    const key = track(sessionVersionKey(parentId));
    const jti = `${runPrefix}:jti`;
    track(revokedTokenKey(jti));
    track(`auth:invalid-before:${parentId}`);

    // 1. Failed restoration on absent marker -> marker stays null
    prismaMock.revokedToken.findMany.mockRejectedValueOnce(new Error("db restoration failed"));
    await reconcileSessionVersionCacheAfterCommit(parentId, 4);
    expect(await client.get(key)).toBeNull();

    // 2. Concurrent higher generation written during failed restoration survives
    prismaMock.revokedToken.findMany.mockImplementationOnce(async () => {
      await client.set(key, "7");
      throw new Error("db restoration failed after concurrent write");
    });
    await reconcileSessionVersionCacheAfterCommit(parentId, 4);
    expect(await client.get(key)).toBe("7");

    // 3. Concurrent tombstone written during failed restoration survives
    await client.del(key);
    prismaMock.revokedToken.findMany.mockImplementationOnce(async () => {
      await client.set(key, DELETED_SESSION_MARKER);
      throw new Error("db restoration failed after concurrent delete");
    });
    await reconcileSessionVersionCacheAfterCommit(parentId, 4);
    expect(await client.get(key)).toBe(DELETED_SESSION_MARKER);

    // 4. Warm-path marker evicted mid-transaction in `invalidateSessionsBefore` -> restores durable rows BEFORE marker creation
    await client.set(key, "3");
    let markerDuringRestore: string | null = "not-null";
    prismaMock.parent.update.mockImplementationOnce(async () => {
      await client.del(key);
      return { id: parentId, sessionVersion: 4 };
    });
    prismaMock.revokedToken.findMany.mockImplementationOnce(async () => {
      markerDuringRestore = await client.get(key);
      return [{ jti, expiresAt: new Date(Date.now() + 3600_000) }];
    });
    expect(await invalidateSessionsBefore(parentId)).toBe(4);
    expect(markerDuringRestore).toBeNull();
    expect(await client.get(revokedTokenKey(jti))).toBe("1");
    expect(await client.get(key)).toBe("4");
    expect(await isParentSessionLive({ sub: parentId, sv: 4, jti })).toBe(false);
    expect(await isParentSessionLive({ sub: parentId, sv: 4, jti: "live-4" })).toBe(true);
  });
});
