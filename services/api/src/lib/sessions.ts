import { randomBytes } from "node:crypto";
import type { FastifyInstance } from "fastify";
import { getRedis } from "../redis.js";

/**
 * Parent session controls (ADR-0014, Phase 2d).
 *
 * Every parent access token carries a `jti`, so a single token can be revoked
 * (`revoked:token:<jti>`), and every parent has a sessions-invalid-before instant
 * (`auth:invalid-before:<parentId>`, unix seconds): a token whose `iat` is older is rejected.
 * `revokeAllRefreshTokens` bumps it, so password reset, MFA enable, logout-all and the theft
 * response now kill the live 7-day access tokens immediately, not only the refresh tokens.
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
}

export function newJti(): string {
  return randomBytes(16).toString("hex");
}

/** Sign a parent access token. `expiresIn` defaults to the standard 7 days. */
export function signParentToken(
  app: FastifyInstance,
  parent: { id: string; familyId: string; role?: string | null },
  opts: { expiresIn?: string; jti?: string } = {},
): { token: string; jti: string } {
  const jti = opts.jti ?? newJti();
  const claims: ParentClaims = { sub: parent.id, familyId: parent.familyId, role: "parent", familyRole: parent.role ?? "owner", jti };
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

/** Invalidate every access token issued before now for this parent (kept for the token lifetime). */
export async function invalidateSessionsBefore(parentId: string, nowSeconds = Math.floor(Date.now() / 1000)): Promise<void> {
  await getRedis().set(invalidBeforeKey(parentId), String(nowSeconds), "EX", 8 * 24 * 3600).catch(() => {});
}

/**
 * Is this parent token still live? Checks the per-token revocation and the parent's
 * invalid-before instant. Fails open only when Redis is unreachable outside production.
 */
export async function isParentSessionLive(user: { sub?: string; jti?: string; iat?: number }): Promise<boolean> {
  const redis = getRedis();
  try {
    if (user.jti && (await redis.get(`revoked:token:${user.jti}`))) return false;
    if (user.sub) {
      const before = await redis.get(invalidBeforeKey(user.sub));
      if (before !== null && typeof user.iat === "number" && user.iat < Number(before)) return false;
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
