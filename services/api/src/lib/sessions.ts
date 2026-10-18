import { randomBytes } from "node:crypto";
import type { FastifyInstance } from "fastify";
import { getRedis } from "../redis.js";

/**
 * Parent session controls (ADR-0014, Phase 2d; revocation generation ADR-0025 / #117).
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

/** Sign a parent access token. `expiresIn` defaults to the standard 7 days. */
export async function signParentToken(
  app: FastifyInstance,
  parent: { id: string; familyId: string; role?: string | null },
  opts: { expiresIn?: string; jti?: string } = {},
): Promise<{ token: string; jti: string }> {
  const jti = opts.jti ?? newJti();
  // Read the version at mint time: a concurrent revocation either lands before this read (and the
  // token is born current) or after it (and the token is born stale), never in between (#117).
  const sv = await currentSessionVersion(parent.id);
  const claims: ParentClaims = { sub: parent.id, familyId: parent.familyId, role: "parent", familyRole: parent.role ?? "owner", jti, sv };
  return { token: app.jwt.sign(claims, { expiresIn: opts.expiresIn ?? PARENT_TOKEN_TTL }), jti };
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

/**
 * The parent's current sessions version; no key means 0 (nothing revoked yet).
 *
 * The key deliberately has no TTL. A version key that expired while a token minted at a higher
 * version was still valid would make that token look current again — a resurrection. One small
 * integer per parent that ever revoked is cheaper than that failure mode.
 */
export async function currentSessionVersion(parentId: string): Promise<number> {
  const raw = await getRedis().get(sessionVersionKey(parentId));
  if (raw === null) return 0;
  const n = Number(raw);
  return Number.isFinite(n) && n > 0 ? Math.floor(n) : 0;
}

/**
 * Invalidate every access token issued before this call for the parent.
 *
 * The counter bump is the authoritative revocation: any token minted before it carries a lower
 * `sv` and is refused, whatever the second on the clock (#117). The epoch below is written only
 * for tokens minted before the counter existed, which have no `sv` to compare.
 */
export async function invalidateSessionsBefore(parentId: string, nowSeconds = Math.floor(Date.now() / 1000)): Promise<void> {
  const redis = getRedis();
  await redis.incrby(sessionVersionKey(parentId), 1).catch(() => {});
  await redis.set(invalidBeforeKey(parentId), String(nowSeconds), "EX", 8 * 24 * 3600).catch(() => {});
}

/**
 * Is this parent token still live? Checks the per-token revocation and the parent's sessions
 * version (or, for a pre-#117 token without `sv`, the legacy invalid-before epoch). Fails open
 * only when Redis is unreachable outside production.
 */
export async function isParentSessionLive(user: ParentSessionClaims): Promise<boolean> {
  const redis = getRedis();
  try {
    if (user.jti && (await redis.get(`revoked:token:${user.jti}`))) return false;
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
    return true;
  } catch (err) {
    if (process.env.NODE_ENV === "production") {
      console.error("[security] session store unreachable — rejecting parent token", err);
      return false;
    }
    return true;
  }
}
