import { beforeEach, describe, expect, it, vi } from "vitest";
import { authRoutes } from "../src/routes/auth.js";
import { deviceRoutes } from "../src/routes/devices.js";
import { familyRoutes } from "../src/routes/family.js";
import { rulesRoutes } from "../src/routes/rules.js";
import { getRedis } from "../src/redis.js";
import { currentSessionVersion, invalidateSessionsBefore, sessionVersionKey, revokedTokenKey, REVOKED_TOKEN_TTL_SECONDS } from "../src/lib/sessions.js";
import { DEVICE_LIVE_TTL_SECONDS, liveDeviceKey, markDeviceRevoked, revokedDeviceKey } from "../src/lib/deviceRevocation.js";
import { DEVICE_TOKEN_TTL_SECONDS } from "../src/lib/deviceToken.js";
import { eraseChildData } from "../src/lib/usageModel.js";
import { runRevokedTokenPrune } from "../src/jobs/revokedTokenPrune.js";
import { MockRedis, authHeader, buildApp, deviceHeader, prismaMock, resetPrismaMock } from "./helpers.js";

vi.mock("../src/db.js", async () => {
  const { prismaMock } = await import("./helpers.js");
  return { prisma: prismaMock };
});
vi.mock("ioredis", async () => {
  const { MockRedis } = await import("./helpers.js");
  return { Redis: MockRedis };
});
vi.mock("argon2", () => ({
  default: { verify: vi.fn(async () => true), hash: vi.fn(async () => "argon2$stub") },
}));

/**
 * ADR-0032 / roadmap 2.7 — every revocation is stored in Postgres, Redis is only a cache.
 *
 * The defect these tests pin: `revoked:device:<id>`, `revoked:token:<jti>` and
 * `auth:session-version:<parentId>` were the *only* copy of a revocation. When a key disappeared —
 * a restarted or evicted ElastiCache node, `snapshot_retention_limit = 0` — a revoked parent session
 * worked again and an unpaired phone's 10-year device token read the child's rules, location history
 * and geofences.
 *
 * Each test names its mutant in the comment above it: the one-line change to the production code
 * that makes it fail. They were run that way before this file was committed (see the PR body).
 */

const PASSWORD = "CorrectHorseBatteryStaple!";
const PARENT = {
  id: "parent-1",
  familyId: "fam-1",
  email: "parent-1@example.com",
  displayName: "Parent One",
  role: "owner",
  permissions: [] as string[],
  passwordHash: "h",
  mfaEnabled: false,
  mfaSecret: null,
};

/**
 * "Redis returned nothing for every key" — the state of a node that just restarted, or that was
 * evicted down to an empty keyspace. `get` resolves `null`, not `undefined`: the code under test
 * distinguishes a miss from a value, and a bare `mockReset()` would answer `undefined` and mask the
 * difference (that is how an earlier generation of this bug hid).
 */
function emptyRedis(): MockRedis {
  const redis = getRedis() as unknown as MockRedis;
  for (const value of Object.values(redis) as unknown[]) {
    const fn = value as { mockReset?: () => void };
    if (typeof fn?.mockReset === "function") fn.mockReset();
  }
  redis.get.mockResolvedValue(null);
  redis.set.mockResolvedValue("OK");
  redis.del.mockResolvedValue(0);
  redis.incrby.mockResolvedValue(1);
  redis.smembers.mockResolvedValue([]);
  redis.on.mockReturnValue(redis);
  return redis;
}

/** A Map-backed Redis that behaves like the real one for the keys these tests use. */
function wireRedisStore(): Map<string, string> {
  const store = new Map<string, string>();
  const redis = getRedis() as unknown as MockRedis;
  redis.get.mockImplementation(async (key: string) => store.get(key) ?? null);
  redis.set.mockImplementation(async (key: string, value: string, ...args: unknown[]) => {
    if (args.includes("NX") && store.has(key)) return null;
    store.set(key, String(value));
    return "OK";
  });
  redis.del.mockImplementation(async (...keys: string[]) => keys.reduce((n, k) => n + (store.delete(k) ? 1 : 0), 0));
  redis.incrby.mockImplementation(async (key: string, by: number) => {
    const next = Number(store.get(key) ?? 0) + by;
    store.set(key, String(next));
    return next;
  });
  redis.smembers.mockResolvedValue([]);
  redis.sadd.mockResolvedValue(1);
  redis.srem.mockResolvedValue(1);
  redis.expire.mockResolvedValue(1);
  return store;
}

/**
 * A family envelope `/v1/family/me` can serialise: one parent, no children. Without it the mutant
 * runs reach the handler and crash on a half-mocked row (a 500), and the claim this test makes —
 * "before the fix this was a 200" — could not be read off the failure.
 */
function familyEnvelope() {
  return {
    id: "fam-1",
    name: "Demo Family",
    region: "US",
    timezone: "UTC",
    timezoneSource: "default",
    parents: [PARENT],
    children: [],
  };
}

beforeEach(() => {
  resetPrismaMock();
});

describe("ADR-0032 claim 1 — the sessions version is durable in Parent.sessionVersion", () => {
  it("a token minted at sv=1 is refused when Redis is empty and the column says 2 (was: 200)", async () => {
    // Mutant: make the miss in `currentSessionVersion` return 0 again (`if (raw === null) return 0;`)
    // — the pre-fix code. Then the empty cache reads as "nothing was revoked" and this is a 200.
    const redis = emptyRedis();
    prismaMock.parent.findUnique.mockResolvedValue({ ...PARENT, sessionVersion: 2 });
    prismaMock.family.findUnique.mockResolvedValue(familyEnvelope());
    const app = await buildApp(familyRoutes, "/v1/family");
    const token = app.jwt.sign(
      { sub: "parent-1", familyId: "fam-1", role: "parent", familyRole: "owner", jti: "jti-1", sv: 1 },
      { expiresIn: "7d" },
    );

    const res = await app.inject({ method: "GET", url: "/v1/family/me", headers: { authorization: `Bearer ${token}` } });

    expect(res.statusCode).toBe(401);
    expect(res.json().error).toBe("session_revoked");
    // The read that decided it was the column, not a default: the miss is answered from the row.
    expect(prismaMock.parent.findUnique).toHaveBeenCalledWith({ where: { id: "parent-1" }, select: { sessionVersion: true } });
    // And the cache was rebuilt from it, with **no TTL**: an expiring marker would let the next call
    // skip the load while the keys it was supposed to carry are gone.
    const rebuilt = redis.set.mock.calls.filter((call) => call[0] === sessionVersionKey("parent-1"));
    expect(rebuilt).toHaveLength(1);
    expect(rebuilt[0]).toEqual([sessionVersionKey("parent-1"), "2", "NX"]);
    await app.close();
  });

  it("a parent that never revoked gets the marker rebuilt as 0 — the read still happens", async () => {
    // Mutant: `if (raw === null) return 0;` (skip the column read). Then no key is written, and the
    // second assertion below — that the column was read — fails.
    const redis = emptyRedis();
    prismaMock.parent.findUnique.mockResolvedValue({ ...PARENT, sessionVersion: 0 });

    expect(await currentSessionVersion("parent-1")).toBe(0);

    expect(prismaMock.parent.findUnique).toHaveBeenCalledWith({ where: { id: "parent-1" }, select: { sessionVersion: true } });
    expect(redis.set).toHaveBeenCalledWith(sessionVersionKey("parent-1"), "0", "NX");
    // A marker with a TTL is the resurrection bug in slow motion.
    const call = redis.set.mock.calls.find((c) => c[0] === sessionVersionKey("parent-1"))!;
    expect(call).toHaveLength(3);
    expect(call).not.toContain("EX");
  });

  it("a revocation increments the column and then the cache, and a failed column write is a 5xx", async () => {
    // Mutant: write Redis first, or swallow the column error (`catch(() => {})`). Either leaves a
    // request reporting success — the 200 — while nothing durable was written.
    wireRedisStore();
    prismaMock.parent.findUnique.mockResolvedValue({ ...PARENT, sessionVersion: 0 });
    prismaMock.parent.update.mockResolvedValue({ ...PARENT, sessionVersion: 1 });
    const app = await buildApp(authRoutes, "/v1/auth");
    const login = await app.inject({ method: "POST", url: "/v1/auth/login", payload: { email: PARENT.email, password: PASSWORD } });
    expect(login.statusCode).toBe(200);
    const { token } = login.json();

    const ok = await app.inject({ method: "POST", url: "/v1/auth/logout-all", headers: { authorization: `Bearer ${token}` } });
    expect(ok.statusCode).toBe(200);
    expect(prismaMock.parent.update).toHaveBeenCalledWith({ where: { id: "parent-1" }, data: { sessionVersion: { increment: 1 } } });
    expect((getRedis() as unknown as MockRedis).incrby).toHaveBeenCalledWith(sessionVersionKey("parent-1"), 1);

    // The token above is dead now (its sv is below the new version), so the failure case signs in
    // again rather than presenting it: this measures the column write, not the guard in front of it.
    const second = await app.inject({ method: "POST", url: "/v1/auth/login", payload: { email: PARENT.email, password: PASSWORD } });
    expect(second.statusCode).toBe(200);
    prismaMock.parent.update.mockRejectedValueOnce(new Error("database unavailable"));
    const failed = await app.inject({ method: "POST", url: "/v1/auth/logout-all", headers: { authorization: `Bearer ${second.json().token}` } });
    expect(failed.statusCode).toBe(500);
    await app.close();
  });

  it("R4: a revocation on a cold cache starts the counter from the column, not from zero", async () => {
    // #349 review, survivor R4. After a Redis restart, a password reset (or logout-all) can be the
    // first thing this parent does: it runs without a session, so nothing has warmed the marker.
    // Mutant: remove `if (cached === null) await loadSessionState(parentId, redis)`. Then INCRBY runs
    // on a missing key and answers 1 while the column says 4, so every token minted at version 1..3
    // reads as current again — and the assertion below sees "1", not "4".
    const store = wireRedisStore();
    prismaMock.parent.findUnique.mockResolvedValue({ ...PARENT, sessionVersion: 3 });
    prismaMock.parent.update.mockResolvedValue({ ...PARENT, sessionVersion: 4 });

    await invalidateSessionsBefore("parent-1");

    expect(store.get(sessionVersionKey("parent-1"))).toBe("4");
    // And the answer a token minted before the revocation gets. sv=3 was current a moment ago.
    prismaMock.family.findUnique.mockResolvedValue(familyEnvelope());
    const app = await buildApp(familyRoutes, "/v1/family");
    const token = app.jwt.sign(
      { sub: "parent-1", familyId: "fam-1", role: "parent", familyRole: "owner", jti: "jti-r4", sv: 3 },
      { expiresIn: "7d" },
    );
    const res = await app.inject({ method: "GET", url: "/v1/family/me", headers: { authorization: `Bearer ${token}` } });
    expect(res.statusCode).toBe(401);
    expect(res.json().error).toBe("session_revoked");
    await app.close();
  });

  it("R5: a failed cache bump drops the marker, so the next request rebuilds and refuses the old token", async () => {
    // #349 review, survivor R5. The test above checks the 5xx but not what the cache holds after it,
    // so "INCRBY before the column write" survived: the column moved, the cache did not, and the
    // stale marker kept answering. With `noeviction` a full node refuses writes but still serves
    // reads and still accepts DEL, so this window is not transient.
    //
    // Mutant: drop the `catch` that deletes the marker in `invalidateSessionsBefore` (the pre-review
    // code). Then the marker still reads "0" after the failure, and the last assertion sees 200.
    const store = wireRedisStore();
    let column = 0;
    prismaMock.parent.findUnique.mockImplementation(async (args: { select?: { sessionVersion?: boolean } }) =>
      args?.select?.sessionVersion ? { ...PARENT, sessionVersion: column } : { ...PARENT },
    );
    prismaMock.parent.update.mockImplementation(async ({ data }: { data: { sessionVersion?: unknown } }) => {
      if (data?.sessionVersion !== undefined) column += 1;
      return { ...PARENT, sessionVersion: column };
    });
    prismaMock.family.findUnique.mockResolvedValue(familyEnvelope());
    const app = await buildApp(authRoutes, "/v1/auth");

    const login = await app.inject({ method: "POST", url: "/v1/auth/login", payload: { email: PARENT.email, password: PASSWORD } });
    expect(login.statusCode).toBe(200);
    const { token } = login.json() as { token: string };
    expect(store.get(sessionVersionKey("parent-1"))).toBe("0");

    // The node refuses the write (a full node under `noeviction`), after the column has moved.
    (getRedis() as unknown as MockRedis).incrby.mockRejectedValueOnce(new Error("OOM command not allowed when used memory > 'maxmemory'"));
    const failed = await app.inject({ method: "POST", url: "/v1/auth/logout-all", headers: { authorization: `Bearer ${token}` } });
    expect(failed.statusCode).toBe(500);
    // The column is the record: 1. The cache no longer contradicts it — the marker is gone, so the
    // next read loads from the column instead of trusting a value that predates the revocation.
    expect(column).toBe(1);
    expect(await getRedis().get(sessionVersionKey("parent-1"))).toBeNull();

    const family = await buildApp(familyRoutes, "/v1/family");
    const after = await family.inject({ method: "GET", url: "/v1/family/me", headers: { authorization: `Bearer ${token}` } });
    expect(after.statusCode).toBe(401);
    expect(after.json().error).toBe("session_revoked");
    // ... and the rebuild put the column's value back.
    expect(store.get(sessionVersionKey("parent-1"))).toBe("1");
    await family.close();
    await app.close();
  });

  it("R5b: a failed token SET drops the marker, so the row is loaded instead of being invisible", async () => {
    // The same window one level down (`revokeTokenOnce`): the row is written, the key is not. While
    // the marker exists the rebuild never runs, so the row would be invisible until something else
    // evicted the marker.
    // Mutant: `throw err` without the `DEL` in `revokeTokenOnce`. Then the marker survives, the
    // reload never happens, and the logged-out token answers 200.
    const store = wireRedisStore();
    prismaMock.parent.findUnique.mockResolvedValue({ ...PARENT, sessionVersion: 0 });
    prismaMock.family.findUnique.mockResolvedValue(familyEnvelope());
    const app = await buildApp(authRoutes, "/v1/auth");
    const login = await app.inject({ method: "POST", url: "/v1/auth/login", payload: { email: PARENT.email, password: PASSWORD } });
    expect(login.statusCode).toBe(200);
    const { token, refreshToken } = login.json() as { token: string; refreshToken: string };
    const claims = app.jwt.decode(token) as { jti: string };
    expect(store.get(sessionVersionKey("parent-1"))).not.toBeNull();

    // Only this token's key is refused: `retireRefreshToken` writes its own `refresh:used:*` key in
    // the same request, and a blanket failure there would fail the request before the row is written.
    const redisMock = getRedis() as unknown as MockRedis;
    const storeSet = redisMock.set.getMockImplementation()!;
    redisMock.set.mockImplementation(async (key: string, value: string, ...args: unknown[]) => {
      if (key === revokedTokenKey(claims.jti)) throw new Error("OOM command not allowed when used memory > 'maxmemory'");
      return storeSet(key, value, ...args);
    });
    const out = await app.inject({ method: "POST", url: "/v1/auth/logout", payload: { refreshToken } });
    expect(out.statusCode).toBe(500);
    // The row landed; the key did not; the marker that would hide it is gone.
    expect(prismaMock.revokedToken.upsert).toHaveBeenCalledWith(expect.objectContaining({ where: { jti: claims.jti } }));
    expect(store.get(revokedTokenKey(claims.jti))).toBeUndefined();
    expect(await getRedis().get(sessionVersionKey("parent-1"))).toBeNull();
    redisMock.set.mockImplementation(storeSet);

    // The next request reloads the parent's logout rows from the table and refuses the token.
    prismaMock.revokedToken.findMany.mockResolvedValue([
      { jti: claims.jti, expiresAt: new Date(Date.now() + 8 * 24 * 3600 * 1000) },
    ]);
    const family = await buildApp(familyRoutes, "/v1/family");
    const after = await family.inject({ method: "GET", url: "/v1/family/me", headers: { authorization: `Bearer ${token}` } });
    expect(after.statusCode).toBe(401);
    expect(after.json().error).toBe("session_revoked");
    await family.close();
    await app.close();
  });
});

describe("ADR-0032 claim 2 — an unpaired device is refused because its row is gone", () => {
  it("a device JWT with no Device row is 401 device_revoked on GET /v1/rules/:childId, with Redis empty", async () => {
    // Mutant: the pre-fix hook, which asked only `revoked:device:<id>` (i.e. drop the row lookup in
    // `deviceVerdict`) — an empty cache then answers "not revoked" and the route returns 200.
    const redis = emptyRedis();
    prismaMock.child.findUnique.mockResolvedValue({ id: "child-1", familyId: "fam-1" });
    prismaMock.ruleSet.findUnique.mockResolvedValue(null);
    prismaMock.device.findUnique.mockResolvedValue(null); // the row is gone: the device was unpaired

    const app = await buildApp(rulesRoutes, "/v1/rules", { sessionGuard: true });
    const res = await app.inject({ method: "GET", url: "/v1/rules/child-1", headers: deviceHeader(app) });

    expect(res.statusCode).toBe(401);
    expect(res.json().error).toBe("device_revoked");
    // The refusal cached itself: one row lookup, then the tombstone answers the next request.
    const tombstone = redis.set.mock.calls.find((c) => c[0] === revokedDeviceKey("dev-1"));
    expect(tombstone).toBeTruthy();
    expect(tombstone!.slice(2)).toEqual(["EX", DEVICE_TOKEN_TTL_SECONDS]); // the device token's own lifetime
    await app.close();
  });

  it("the same request without the global guard is a 200 — the refusal is the guard, not the route", async () => {
    // The positive control for the test above. Without it, a 401 from the route's own preHandlers
    // could be mistaken for the guard working (the #310 lesson: a check that cannot distinguish the
    // mechanism it names from any other refusal is not evidence).
    emptyRedis();
    prismaMock.child.findUnique.mockResolvedValue({ id: "child-1", familyId: "fam-1" });
    prismaMock.ruleSet.findUnique.mockResolvedValue(null);
    prismaMock.device.findUnique.mockResolvedValue(null);

    const app = await buildApp(rulesRoutes, "/v1/rules");
    const res = await app.inject({ method: "GET", url: "/v1/rules/child-1", headers: deviceHeader(app) });
    expect(res.statusCode).toBe(200);
    await app.close();
  });

  it("a live device costs one row lookup per 5 minutes, not one per request", async () => {
    // Mutant: drop the positive cache (never SET `device:live:<id>`), and the second request pays a
    // second database read: the cost this ADR accepts is "one lookup per device per 5 minutes".
    const store = wireRedisStore();
    prismaMock.child.findUnique.mockResolvedValue({ id: "child-1", familyId: "fam-1" });
    prismaMock.ruleSet.findUnique.mockResolvedValue(null);
    prismaMock.device.findUnique.mockResolvedValue({ id: "dev-1" });

    const app = await buildApp(rulesRoutes, "/v1/rules", { sessionGuard: true });
    const first = await app.inject({ method: "GET", url: "/v1/rules/child-1", headers: deviceHeader(app) });
    expect(first.statusCode).toBe(200);
    expect(prismaMock.device.findUnique).toHaveBeenCalledTimes(1);
    expect(store.has(liveDeviceKey("dev-1"))).toBe(true);
    expect((getRedis() as unknown as MockRedis).set).toHaveBeenCalledWith(liveDeviceKey("dev-1"), "1", "EX", DEVICE_LIVE_TTL_SECONDS);

    // The second request is answered by the cache: the mock still returns the row, so a second read
    // would be visible.
    const second = await app.inject({ method: "GET", url: "/v1/rules/child-1", headers: deviceHeader(app) });
    expect(second.statusCode).toBe(200);
    expect(prismaMock.device.findUnique).toHaveBeenCalledTimes(1);
    await app.close();
  });

  it("evicting revoked:device:<id> alone does not resurrect an unpaired device (claim 4)", async () => {
    // Mutant: the pre-fix hook (Redis-only). `redis.del` below is the eviction this ADR exists for;
    // with the row gone, the only correct answer is still 401.
    const store = wireRedisStore();
    prismaMock.child.findUnique.mockResolvedValue({ id: "child-1", familyId: "fam-1" });
    prismaMock.ruleSet.findUnique.mockResolvedValue(null);
    prismaMock.device.findUnique.mockResolvedValue(null);

    // The unpair's own writes: the positive cache goes, the tombstone arrives.
    store.set(liveDeviceKey("dev-1"), "1");
    await markDeviceRevoked("dev-1");
    expect(store.has(liveDeviceKey("dev-1"))).toBe(false);
    expect(store.get(revokedDeviceKey("dev-1"))).toBeTruthy();

    // Evict exactly one key: the tombstone. `device:live` is already absent — this is the state a
    // `maxmemory-policy = allkeys-lru` node produces, one key at a time.
    store.delete(revokedDeviceKey("dev-1"));

    const app = await buildApp(rulesRoutes, "/v1/rules", { sessionGuard: true });
    const res = await app.inject({ method: "GET", url: "/v1/rules/child-1", headers: deviceHeader(app) });
    expect(res.statusCode).toBe(401);
    expect(res.json().error).toBe("device_revoked");
    // ... and the verdict was written back, so the next request does not need the database.
    expect(store.get(revokedDeviceKey("dev-1"))).toBeTruthy();
    await app.close();
  });

  it("R12: the tombstone wins over the positive cache when both keys exist", async () => {
    // #349 review, survivor R12. A verdict that read the row just before an unpair can write
    // `device:live` just after it, so both keys can be present at once. The tombstone-first order is
    // what makes the stale positive key harmless, and the row below is deliberately present too, so
    // neither the cache nor the database could produce the 401 on its own.
    // Mutant: read `device:live` before `revoked:device` in `deviceVerdict` — then this is a 200.
    const store = wireRedisStore();
    prismaMock.child.findUnique.mockResolvedValue({ id: "child-1", familyId: "fam-1" });
    prismaMock.ruleSet.findUnique.mockResolvedValue(null);
    prismaMock.device.findUnique.mockResolvedValue({ id: "dev-1" });
    store.set(revokedDeviceKey("dev-1"), new Date().toISOString());
    store.set(liveDeviceKey("dev-1"), "1");

    const app = await buildApp(rulesRoutes, "/v1/rules", { sessionGuard: true });
    const res = await app.inject({ method: "GET", url: "/v1/rules/child-1", headers: deviceHeader(app) });
    expect(res.statusCode).toBe(401);
    expect(res.json().error).toBe("device_revoked");
    // The database was not consulted at all: the tombstone answers before the row would.
    expect(prismaMock.device.findUnique).not.toHaveBeenCalled();
    await app.close();
  });

  it("unpairing drops the positive cache and writes the tombstone; a failed cache write is a 5xx", async () => {
    // Mutant: `await redis.del(liveDeviceKey(id))` removed → an unpaired device's `device:live` cache
    // outlives the row, and every request keeps answering 200 for 5 minutes.
    const store = wireRedisStore();
    prismaMock.device.findUnique.mockResolvedValue({ id: "dev-1", childId: "child-1", child: { familyId: "fam-1" } });
    store.set(liveDeviceKey("dev-1"), "1");
    const app = await buildApp(deviceRoutes, "/v1/devices");
    const del = await app.inject({ method: "DELETE", url: "/v1/devices/dev-1", headers: authHeader(app) });
    expect(del.statusCode).toBe(200);
    expect(store.has(liveDeviceKey("dev-1"))).toBe(false);
    expect(store.get(revokedDeviceKey("dev-1"))).toBeTruthy();

    // Fail closed: a Redis that rejects the tombstone must not produce a 200 that says "unpaired".
    prismaMock.device.findUnique.mockResolvedValue({ id: "dev-1", childId: "child-1", child: { familyId: "fam-1" } });
    (getRedis() as unknown as MockRedis).set.mockRejectedValueOnce(new Error("redis unavailable"));
    const failed = await app.inject({ method: "DELETE", url: "/v1/devices/dev-1", headers: authHeader(app) });
    expect(failed.statusCode).toBe(500);
    await app.close();
  });

  it("child erasure drops each device's positive cache as well as writing its tombstone", async () => {
    // Mutant: the pre-fix `redis.set(revoked:device, …)` without the `device:live` delete. The erasure
    // then leaves a positive cache entry that outlives the deletion by up to 5 minutes.
    const store = wireRedisStore();
    prismaMock.device.findMany.mockResolvedValue([{ id: "dev-1" }, { id: "dev-2" }]);
    store.set(liveDeviceKey("dev-1"), "1");
    store.set(liveDeviceKey("dev-2"), "1");

    const result = await eraseChildData("child-1", DEVICE_TOKEN_TTL_SECONDS);

    expect(result.deletedDevices).toEqual(["dev-1", "dev-2"]);
    expect(store.has(liveDeviceKey("dev-1"))).toBe(false);
    expect(store.has(liveDeviceKey("dev-2"))).toBe(false);
    expect(store.get(revokedDeviceKey("dev-1"))).toBeTruthy();
    expect(store.get(revokedDeviceKey("dev-2"))).toBeTruthy();
  });
});

describe("ADR-0032 claim 3 — a single logout survives an emptied Redis", () => {
  it("the revoked jti is still refused after the cache is wiped", async () => {
    // Mutant: skip the `revokedToken.findMany` load in `loadSessionState`. The version key is rebuilt
    // (as 0) and the jti key is not, so the logged-out token answers 200 again.
    const store = wireRedisStore();
    prismaMock.parent.findUnique.mockResolvedValue({ ...PARENT, sessionVersion: 0 });
    prismaMock.family.findUnique.mockResolvedValue(familyEnvelope());
    const app = await buildApp(authRoutes, "/v1/auth");

    const login = await app.inject({ method: "POST", url: "/v1/auth/login", payload: { email: PARENT.email, password: PASSWORD } });
    expect(login.statusCode).toBe(200);
    const { token, refreshToken } = login.json() as { token: string; refreshToken: string };
    const claims = app.jwt.decode(token) as { jti: string; sv: number };

    const out = await app.inject({ method: "POST", url: "/v1/auth/logout", payload: { refreshToken } });
    expect(out.statusCode).toBe(200);
    // The record is a row, written in the same request as the key.
    expect(prismaMock.revokedToken.upsert).toHaveBeenCalledWith({
      where: { jti: claims.jti },
      create: { jti: claims.jti, parentId: "parent-1", expiresAt: expect.any(Date) },
      update: { expiresAt: expect.any(Date) },
    });
    expect(store.get(revokedTokenKey(claims.jti))).toBe("1");

    // The restart: every key is gone, the rows are not.
    const expiresAt = new Date(Date.now() + 7 * 24 * 3600 * 1000);
    store.clear();
    prismaMock.revokedToken.findMany.mockResolvedValue([{ jti: claims.jti, expiresAt }]);

    const family = await buildApp(familyRoutes, "/v1/family");
    const res = await family.inject({ method: "GET", url: "/v1/family/me", headers: { authorization: `Bearer ${token}` } });
    expect(res.statusCode).toBe(401);
    expect(res.json().error).toBe("session_revoked");

    // The load restored the key with the row's own remaining lifetime, not a fresh 8 days. The last
    // write of that key is the reload (the logout wrote it first, with 8 days).
    const restored = store.get(revokedTokenKey(claims.jti));
    expect(restored).toBe("1");
    const writes = (getRedis() as unknown as MockRedis).set.mock.calls.filter((c) => c[0] === revokedTokenKey(claims.jti));
    expect(writes).toHaveLength(2);
    const reload = writes[writes.length - 1];
    expect(reload[2]).toBe("EX");
    expect(Number(reload[3])).toBeGreaterThan(6 * 24 * 3600);
    expect(Number(reload[3])).toBeLessThanOrEqual(7 * 24 * 3600);
    await family.close();
    await app.close();
  });

  it("the logout row's horizon is the token's own end, and the prune deletes only expired rows", async () => {
    // Mutant: prune on `createdAt` (or with no bound at all) — the first assertion catches a row that
    // would be deleted while its token was still presentable; a no-bound delete would take both.
    wireRedisStore();
    prismaMock.parent.findUnique.mockResolvedValue({ ...PARENT, sessionVersion: 0 });
    const app = await buildApp(authRoutes, "/v1/auth");
    const login = await app.inject({ method: "POST", url: "/v1/auth/login", payload: { email: PARENT.email, password: PASSWORD } });
    const { refreshToken } = login.json() as { refreshToken: string };
    expect((await app.inject({ method: "POST", url: "/v1/auth/logout", payload: { refreshToken } })).statusCode).toBe(200);

    const written = prismaMock.revokedToken.upsert.mock.calls[0][0] as { create: { expiresAt: Date } };
    const horizon = written.create.expiresAt.getTime() - Date.now();
    expect(horizon).toBeGreaterThan((REVOKED_TOKEN_TTL_SECONDS - 60) * 1000);
    expect(horizon).toBeLessThanOrEqual(REVOKED_TOKEN_TTL_SECONDS * 1000);

    const now = new Date("2026-10-24T03:00:00.000Z");
    prismaMock.revokedToken.deleteMany.mockResolvedValue({ count: 3 });
    expect(await runRevokedTokenPrune(now)).toEqual({ deleted: 3 });
    expect(prismaMock.revokedToken.deleteMany).toHaveBeenCalledWith({ where: { expiresAt: { lt: now } } });
    await app.close();
  });
});
