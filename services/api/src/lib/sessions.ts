import { randomBytes } from "node:crypto";
import type { FastifyInstance } from "fastify";
import type { Redis } from "ioredis";
import { getRedis } from "../redis.js";
import { prisma } from "../db.js";

/**
 * Parent session controls (ADR-0014, Phase 2d; revocation generation ADR-0025 / #117; durability
 * ADR-0032 / roadmap 2.7).
 *
 * Every parent access token carries a `jti`, so a single token can be revoked
 * (`revoked:token:<jti>`), and an `sv` — the parent's sessions version read from
 * `auth:session-version:<parentId>` when the token is minted. `revokeAllRefreshTokens` increments
 * that counter, so password reset, MFA enable, logout-all and the theft response kill every token
 * minted before the revocation, **including one minted in the same wall-clock second** (#117).
 *
 * The counter is deliberate: the old `auth:invalid-before:<parentId>` epoch compared
 * second-resolution `iat` values, so a token minted in the revocation second survived (`<`), and
 * making it inclusive (`<=`) would still leave a clock-skew hole between the minting and revoking
 * instances. Integers in the shared Redis have neither problem.
 *
 * Since ADR-0032 neither the counter nor a single-logout record lives only in Redis: the counter is
 * `Parent.sessionVersion`, the logout is a `RevokedToken` row, and the Redis keys are caches the
 * database rebuilds on a miss. Before that, a restarted or evicted node handed a revoked parent
 * their sessions back, because a missing key read as "nothing was revoked".
 *
 * Tokens minted before #117 carry no `sv`; they are judged by the legacy epoch, now inclusively
 * (`iat <= epoch`), and revocation still writes that epoch for them. Drop the legacy branch once
 * no pre-#117 token can be live (one token lifetime, 7 days, after the last old instance is gone).
 */

export const PARENT_TOKEN_TTL = "7d";

export interface ParentClaims {
  sub: string;
  familyId: string;
  /** Always "parent" — the JWT role selects the parent surface; the family role is a separate claim. */
  role: "parent";
  /** owner | co-parent | guardian (the Parent row's `role`). */
  familyRole: string;
  jti: string;
  /** Sessions version at mint time (#117), compared with `auth:session-version:<sub>`. */
  sv: number;
}

/** The claims this module reads from a verified parent JWT (all optional: it may be a legacy token). */
export interface ParentSessionClaims {
  sub?: string;
  jti?: string;
  iat?: number;
  sv?: number;
}

export function newJti(): string {
  return randomBytes(16).toString("hex");
}

/**
 * Sign a parent access token. `expiresIn` defaults to the standard 7 days.
 *
 * `opts.sv` lets the caller supply a version it read (and checked) earlier in the same operation.
 * `/token/refresh` uses it so the version stamped into the token is the one that was compared with
 * the refresh record, not a second, later read (#158). Without it the version is read here.
 * The effective `sv` is returned so callers can stamp it into an accompanying refresh record.
 */
export async function signParentToken(
  app: FastifyInstance,
  parent: { id: string; familyId: string; role?: string | null },
  opts: { expiresIn?: string; jti?: string; sv?: number } = {},
): Promise<{ token: string; jti: string; sv: number }> {
  const jti = opts.jti ?? newJti();
  // Read the version at mint time: a concurrent revocation either lands before this read (and the
  // token is born current) or after it (and the token is born stale), never in between (#117).
  const sv = opts.sv ?? await currentSessionVersion(parent.id);
  const claims: ParentClaims = { sub: parent.id, familyId: parent.familyId, role: "parent", familyRole: parent.role ?? "owner", jti, sv };
  return { token: app.jwt.sign(claims, { expiresIn: opts.expiresIn ?? PARENT_TOKEN_TTL }), jti, sv };
}

/**
 * Is this JWT a session bearer credential? Purpose-scoped tokens (today the 15-minute
 * `password_reset` link) are valid only on the endpoint designed to consume them, never as a
 * general `Authorization: Bearer` — #146: a reset token reached `/mfa/enroll` and, with the
 * password the reset had just set, replaced the second factor.
 *
 * A session token has no `purpose`, or explicitly `purpose:"session"`.
 */
export function isBearerSession(claims: { purpose?: unknown } | null | undefined): boolean {
  return claims?.purpose === undefined || claims.purpose === "session";
}

export const invalidBeforeKey = (parentId: string) => `auth:invalid-before:${parentId}`;
export const sessionVersionKey = (parentId: string) => `auth:session-version:${parentId}`;
export const revokedTokenKey = (jti: string) => `revoked:token:${jti}`;

/**
 * How long a single-logout record lives: the 8 days ADR-0014 gave the key, longer than the 7-day
 * access token it kills, so a record can never expire under a token still presentable. The same
 * number is the `RevokedToken.expiresAt` horizon, so the Redis key and the row end together.
 */
export const REVOKED_TOKEN_TTL_SECONDS = 8 * 24 * 3600;

/** Parse a stored version: anything absent, non-numeric or negative means "nothing revoked". */
function parseVersion(raw: string | null): number {
  if (raw === null) return 0;
  const n = Number(raw);
  return Number.isFinite(n) && n > 0 ? Math.floor(n) : 0;
}

/**
 * Read a parent's revocation state from the records, on a miss (ADR-0032).
 *
 * The `Parent.sessionVersion` column and the `RevokedToken` rows are the truth; Redis is a cache of
 * them. When the version key is missing — a restarted or evicted node, or a parent that never
 * revoked — this rebuilds it **and** that parent's unexpired single-logout keys, before anything
 * answers. That is what stops an eviction from resurrecting a session that was revoked (this
 * function used to have no fallback at all: a miss meant "0", meaning "nothing revoked").
 *
 * Write order matters twice:
 *  - the token keys before the version key, because the version key is this parent's "loaded"
 *    marker. A failure partway leaves the marker absent, so the next call loads again instead of
 *    trusting half a cache — and it rejects, which the caller answers as 5xx.
 *  - the marker with `SET NX`: a concurrent loader or revocation that already wrote it has a value
 *    at least as new, and must not be rolled back to the value this call read a moment earlier.
 *
 * The marker never has a TTL, even when the value is 0: an expiring marker would let the next call
 * skip the load while the token keys it was supposed to carry are gone.
 */
async function loadSessionState(parentId: string, redis: Redis): Promise<number> {
  const row = await prisma.parent.findUnique({ where: { id: parentId }, select: { sessionVersion: true } });
  const version = typeof row?.sessionVersion === "number" ? row.sessionVersion : 0;
  const now = Date.now();
  const tokens = await prisma.revokedToken.findMany({
    where: { parentId, expiresAt: { gt: new Date(now) } },
    select: { jti: true, expiresAt: true },
  });
  for (const token of tokens) {
    const ttl = Math.ceil((new Date(token.expiresAt).getTime() - now) / 1000);
    if (ttl > 0) await redis.set(revokedTokenKey(token.jti), "1", "EX", ttl);
  }
  const stored = await redis.set(sessionVersionKey(parentId), String(version), "NX");
  if (stored === "OK") return version;
  // Another caller wrote the marker first: answer with what the cache now holds, never with the
  // value this call read before it. If it vanished again in between, the column read above is still
  // the answer — this function never returns 0 without having read the record.
  const settled = await redis.get(sessionVersionKey(parentId));
  return settled === null ? version : parseVersion(settled);
}

/**
 * The parent's current sessions version; no key means "read the record and rebuild the key".
 *
 * The key deliberately has no TTL. A version key that expired while a token minted at a higher
 * version was still valid would make that token look current again — a resurrection. One small
 * integer per parent that ever revoked is cheaper than that failure mode.
 *
 * A miss is **not** 0 any more (ADR-0032): it is a read of `Parent.sessionVersion` plus the load in
 * `loadSessionState`. Returning 0 without that read is the defect that let a restarted Redis hand a
 * revoked parent their sessions back.
 */
export async function currentSessionVersion(parentId: string): Promise<number> {
  const redis = getRedis();
  const raw = await redis.get(sessionVersionKey(parentId));
  if (raw !== null) return parseVersion(raw);
  return loadSessionState(parentId, redis);
}

/**
 * Invalidate every access token issued before this call for the parent.
 *
 * The counter bump is the authoritative revocation: any token minted before it carries a lower
 * `sv` and is refused, whatever the second on the clock (#117). The epoch below is written only
 * for tokens minted before the counter existed, which have no `sv` to compare.
 *
 * The bump is **not** best-effort (#158, #135). If either write fails, every token stays live, so
 * the function rejects and the caller answers 5xx rather than report a revocation that did not
 * happen. The legacy epoch is only a migration aid and stays best-effort — a failed write there
 * cannot keep an `sv` token alive.
 *
 * Durability (ADR-0032): the column is the record and the Redis key is its cache, so the column is
 * incremented before the cache write, and a failed column write never reaches Redis at all. The
 * cache is loaded from the column first when the key is missing — otherwise `INCRBY` on a cold key
 * would answer 1 while the column held N, and versions 1..N-1 would read as current again.
 *
 * If the `INCRBY` fails the marker is deleted before the error is rethrown (#349 review): a key that
 * still exists is never re-read, so leaving the old value behind would let the cache outvote the
 * column for as long as the node refused writes.
 */
export async function invalidateSessionsBefore(parentId: string, nowSeconds = Math.floor(Date.now() / 1000)): Promise<void> {
  const redis = getRedis();
  const cached = await redis.get(sessionVersionKey(parentId));
  if (cached === null) await loadSessionState(parentId, redis);
  await prisma.parent.update({ where: { id: parentId }, data: { sessionVersion: { increment: 1 } } });
  try {
    await redis.incrby(sessionVersionKey(parentId), 1);
  } catch (err) {
    // The column moved and the cache did not: drop the marker so the next read rebuilds from the
    // column. This is not hypothetical — with `noeviction` a full node refuses writes but still
    // serves reads and still accepts DEL, so without this the old marker would keep answering and
    // the token this request was meant to kill would stay live while the node stayed full.
    await redis.del(sessionVersionKey(parentId)).catch(() => {});
    throw err;
  }
  await redis.set(invalidBeforeKey(parentId), String(nowSeconds), "EX", 8 * 24 * 3600).catch(() => {});
}

/**
 * Is this parent token still live? Checks the parent's sessions version (or, for a pre-#117 token
 * without `sv`, the legacy invalid-before epoch) and then the per-token revocation. Fails open only
 * when the session store is unreachable outside production.
 *
 * The version is resolved **before** the `jti` is read (ADR-0032): on a cold Redis, resolving it is
 * what loads this parent's `RevokedToken` keys, so the `jti` check after it sees a single-logout
 * record that a restart had dropped. Same two round trips as before, in the order that is correct.
 */
export async function isParentSessionLive(user: ParentSessionClaims): Promise<boolean> {
  const redis = getRedis();
  try {
    if (user.sub) {
      if (typeof user.sv === "number") {
        if (user.sv < (await currentSessionVersion(user.sub))) return false;
      } else {
        // Legacy token: second-resolution `iat`, compared inclusively so a token minted in the
        // revocation second is dead as well (#117).
        const before = await redis.get(invalidBeforeKey(user.sub));
        if (before !== null && typeof user.iat === "number" && user.iat <= Number(before)) return false;
      }
    }
    if (user.jti && (await redis.get(revokedTokenKey(user.jti)))) return false;
    return true;
  } catch (err) {
    if (process.env.NODE_ENV === "production") {
      console.error("[security] session store unreachable — rejecting parent token", err);
      return false;
    }
    return true;
  }
}

/**
 * Revoke one access token by `jti`, durably (ADR-0032).
 *
 * Writes the `RevokedToken` row first and the Redis key second, in the same request: the row is the
 * record, the key is the cache `loadSessionState` rebuilds. Either write failing rejects — a logout
 * that reported success while the only copy of the revocation was lost is exactly the defect this
 * change removes.
 *
 * A failed `SET` leaves the row written and the key absent, which only matters while this parent's
 * marker still exists: an existing marker is never re-read, so the rebuild that would load the new
 * row would not run. So the marker is dropped before the error is rethrown, and the next request
 * reloads and finds the row. (Same reason as `invalidateSessionsBefore`: a node can refuse writes and
 * still accept `DEL`.) This key is not this token's key — it is the parent's, and the parent is where
 * that rebuild starts.
 *
 * `expiresAt` is the token's own end, not "now + something": the row must be prunable as soon as the
 * token it revokes could no longer be presented, and the key gets the same horizon so both halves of
 * one revocation expire together.
 */
export async function revokeTokenOnce(jti: string, parentId: string, ttlSeconds = REVOKED_TOKEN_TTL_SECONDS): Promise<void> {
  const expiresAt = new Date(Date.now() + ttlSeconds * 1000);
  await prisma.revokedToken.upsert({
    where: { jti },
    create: { jti, parentId, expiresAt },
    update: { expiresAt },
  });
  const redis = getRedis();
  try {
    await redis.set(revokedTokenKey(jti), "1", "EX", ttlSeconds);
  } catch (err) {
    if (parentId) await redis.del(sessionVersionKey(parentId)).catch(() => {});
    throw err;
  }
}
