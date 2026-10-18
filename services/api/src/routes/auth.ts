import type { FastifyInstance, FastifyReply, FastifyRequest } from "fastify";
import { createHash, randomBytes, timingSafeEqual } from "node:crypto";
import argon2 from "argon2";
import { z } from "zod";
import { prisma } from "../db.js";
import { appPublicUrl, getEmailSender } from "../lib/email/index.js";
import { passwordResetEmail } from "../lib/email/templates.js";
import { generateTotpSecret, totpAtCounter } from "../lib/totp.js";
import { getRedis } from "../redis.js";
import { isValidTimeZone } from "../lib/digestSchedule.js";
import { currentSessionVersion, invalidateSessionsBefore, isBearerSession, isParentSessionLive, signParentToken } from "../lib/sessions.js";
import { decryptSecret, encryptSecret, isEncryptedSecret } from "../lib/secretVault.js";

const RegisterSchema = z.object({
  email: z.string().email().transform((e) => e.trim().toLowerCase()),
  password: z.string().min(12),
  displayName: z.string().min(1),
  familyName: z.string().min(1),
  region: z.enum(["US", "EU", "UK", "OTHER"]),
  // ADR-0020: optional, additive; existing clients send nothing and nothing changes.
  timezone: z.string().max(64).optional(),
});

const LoginSchema = z.object({
  email: z.string().email().transform((e) => e.trim().toLowerCase()),
  password: z.string(),
  // ADR-0020: the device zone, used only to fill a family that has never set one.
  timezone: z.string().max(64).optional(),
});

/**
 * Re-authentication for replacing an already-enrolled TOTP secret: the account password (preferred)
 * or a code from the current authenticator. Either one proves the person holding the session is the
 * parent; without it a stolen session could swap the second factor for its own.
 */
const MfaEnrollSchema = z.object({
  password: z.string().min(1).optional(),
  code: z.string().regex(/^\d{6}$/).optional(),
});

/**
 * Verify a login TOTP code with replay protection (review 3.1): the accepted
 * time-step counter is stored per parent, so a captured code cannot be reused
 * within its validity window.
 */
async function verifyTotpFresh(parentId: string, storedSecret: string | null, code: string): Promise<boolean> {
  const secret = decryptSecret(storedSecret);
  if (!secret) return false;
  const now = Math.floor(Date.now() / 1000 / 30);
  let matched: number | null = null;
  for (const counter of [now - 1, now, now + 1]) {
    if (timingSafeEq(totpAtCounter(secret, counter), code)) { matched = counter; break; }
  }
  if (matched === null) return false;
  const redis = getRedis();
  const key = `mfa:lastcounter:${parentId}`;
  // Handoff item 7: replay protection must fail CLOSED in production. When Redis is
  // unreachable there, reject the code loudly instead of silently disabling the check.
  const production = process.env.NODE_ENV === "production";
  try {
    const last = await redis.get(key);
    if (last !== null && Number(last) >= matched) return false;
    await redis.set(key, String(matched));
    return true;
  } catch (err) {
    if (production) {
      console.error(`[security] MFA replay store unreachable for ${parentId} — rejecting login`, err);
      return false;
    }
    console.warn("[security] MFA replay store unreachable; replay protection disabled (dev only)", err);
    return true;
  }
}

/** Constant-time comparison of two equal-length digit strings. */
function timingSafeEq(a: string, b: string): boolean {
  const ba = Buffer.from(a.padStart(6, "0"));
  const bb = Buffer.from(b.padStart(6, "0"));
  return ba.length === bb.length && timingSafeEqual(ba, bb);
}

export async function authRoutes(app: FastifyInstance) {
  // Review API-11: stricter bucket on auth endpoints (brute-force protection).
  const RL = { rateLimit: { max: 20, timeWindow: "1 minute" } };
  const REFRESH_TTL_MS = 30 * 24 * 60 * 60 * 1000; // 30 days

  // --- Redis-backed refresh-token store (handoff items 1-3) ---
  // Live key  refresh:{sha256(token)}            -> JSON {parentId, expiresAt, jti, sv} (30 d TTL)
  // Marker    refresh:used:{sha256(token)}       -> "1" (rotation/reuse detection, same TTL)
  // Index     refresh:index:{parentId}           -> SET of live token hashes (for logout-all); TTL re-armed
  //                                                  to 30 d on every issue, members removed on
  //                                                  rotation / logout / expiry (#57)
  // `sv` is the parent's sessions version at issue time (#158). `/token/refresh` refuses a record
  // whose `sv` is below the current version, so a token issued before a revocation can never mint
  // again, whatever the interleaving with the revocation.
  const hashToken = (token: string) => createHash("sha256").update(token).digest("hex");
  const liveKey = (hash: string) => `refresh:${hash}`;
  const usedKey = (hash: string) => `refresh:used:${hash}`;
  const indexKey = (parentId: string) => `refresh:index:${parentId}`;

  /** Issue a new opaque refresh token, storing only its sha256 hash in Redis. */
  const issueRefreshToken = async (parentId: string, sv: number, accessJti?: string): Promise<string> => {
    const token = randomBytes(48).toString("hex");
    const hash = hashToken(token);
    const redis = getRedis();
    await redis.set(liveKey(hash), JSON.stringify({ parentId, expiresAt: Date.now() + REFRESH_TTL_MS, jti: accessJti ?? null, sv }), "EX", Math.floor(REFRESH_TTL_MS / 1000));
    // The access token issued alongside: `/logout` with this refresh token revokes it too (ADR-0014).
    if (accessJti) await redis.set(`refresh:jwt:${hash}`, accessJti, "EX", Math.floor(REFRESH_TTL_MS / 1000));
    await redis.sadd(indexKey(parentId), hash);
    // #57: a SET member does not expire with the live key it indexes, so the index itself is bounded —
    // it lives exactly as long as the newest token it could still reference. Refreshed on every issue,
    // so an abandoned index disappears one refresh-lifetime after the last login even if a removal
    // path is ever missed. The members are still removed eagerly below (rotation, logout, expiry).
    await redis.expire(indexKey(parentId), Math.floor(REFRESH_TTL_MS / 1000));
    return token;
  };

  /**
   * Retire one refresh token: drop the live key, mark the hash consumed (reuse detection), and remove
   * it from its parent's index (#57 — a logout or a naturally expired token used to leave the hash in
   * the SET forever). `parentId` comes from the live record when it is still there; a token whose
   * record is already gone needs no index work.
   */
  const retireRefreshToken = async (hash: string, parentId: string | null): Promise<void> => {
    const redis = getRedis();
    await redis.del(liveKey(hash));
    await redis.set(usedKey(hash), "1", "EX", Math.floor(REFRESH_TTL_MS / 1000));
    if (parentId) await redis.srem(indexKey(parentId), hash);
  };

  /** Revoke every refresh token of a parent (password reset / MFA enable / logout-all / theft). */
  const revokeAllRefreshTokens = async (parentId: string): Promise<void> => {
    const redis = getRedis();
    const hashes = await redis.smembers(indexKey(parentId)).catch(() => [] as string[]);
    for (const hash of hashes) {
      await redis.del(liveKey(hash));
      await redis.set(usedKey(hash), "1", "EX", Math.floor(REFRESH_TTL_MS / 1000));
    }
    await redis.del(indexKey(parentId));
    // ADR-0014 / ADR-0025: the live access tokens die with the sessions, not 7 days later. The
    // counter bump also covers a token minted in this same second (#117).
    await invalidateSessionsBefore(parentId);
  };

  app.post("/register", { config: RL }, async (req, reply) => {
    const parsed = RegisterSchema.safeParse(req.body);
    if (!parsed.success) return reply.code(400).send({ error: parsed.error.flatten() });
    const { email: rawEmail, password, displayName, familyName, region, timezone } = parsed.data;
    const email = rawEmail.trim().toLowerCase();

    const existing = await prisma.parent.findUnique({ where: { email } });
    if (existing) return reply.code(409).send({ error: "email_taken" });

    const passwordHash = await argon2.hash(password);
    const result = await prisma.$transaction(async (tx) => {
      const zone = timezone && isValidTimeZone(timezone) ? timezone : null;
      const family = await tx.family.create({
        data: { name: familyName, region, ...(zone ? { timezone: zone, timezoneSource: "device" } : {}) },
      });
      const parent = await tx.parent.create({
        data: { familyId: family.id, email, passwordHash, displayName, role: "owner" },
      });
      return { family, parent };
    });

    const { token, jti, sv } = await signParentToken(app, { id: result.parent.id, familyId: result.family.id, role: "owner" });
    return reply.code(201).send({ token, refreshToken: await issueRefreshToken(result.parent.id, sv, jti), parent: { id: result.parent.id, email, displayName } });
  });

  app.post("/login", { config: RL }, async (req, reply) => {
    const parsed = LoginSchema.safeParse(req.body);
    if (!parsed.success) return reply.code(400).send({ error: parsed.error.flatten() });
    const email = parsed.data.email.trim().toLowerCase();
    const parent = await prisma.parent.findUnique({ where: { email } });
    if (!parent) return reply.code(401).send({ error: "invalid_credentials" });
    const ok = await argon2.verify(parent.passwordHash, parsed.data.password);
    if (!ok) return reply.code(401).send({ error: "invalid_credentials" });
    // Review 3.1: MFA is enforced here — a TOTP code is required when enabled.
    if (parent.mfaEnabled) {
      const code = (req.body as { code?: unknown })?.code;
      if (typeof code !== "string" || !(await verifyTotpFresh(parent.id, parent.mfaSecret, code))) {
        return reply.code(401).send({ error: "mfa_required" });
      }
    }
    // Lazy upgrade of a legacy plaintext MFA secret to the encrypted form (ADR-0014).
    if (parent.mfaSecret && !isEncryptedSecret(parent.mfaSecret)) {
      try {
        await prisma.parent.update({ where: { id: parent.id }, data: { mfaSecret: encryptSecret(parent.mfaSecret) } });
      } catch (err) {
        req.log.warn({ err }, "mfa secret lazy encryption failed");
      }
    }
    // ADR-0020 decision 4: the device fills a family ONCE. The guard is `timezoneSource = 'default'`,
    // not `<> 'parent'` - with the latter every login re-filled the zone, so a parent travelling abroad
    // moved the family's digest (caught in review of #101, see the ADR amendment). One statement, so
    // there is no read-then-write race with a parent saving an explicit choice at the same moment.
    const zone = parsed.data.timezone;
    if (zone && isValidTimeZone(zone)) {
      await prisma.family.updateMany({
        where: { id: parent.familyId, timezoneSource: "default" },
        data: { timezone: zone, timezoneSource: "device" },
      }).catch((err) => req.log.warn({ err }, "timezone fill failed"));
    }
    const { token, jti, sv } = await signParentToken(app, parent);
    return { token, refreshToken: await issueRefreshToken(parent.id, sv, jti) };
  });

  /**
   * Require a live parent SESSION token for the MFA and logout-all endpoints.
   *
   * Issue #146: signature validity is not authorization. A password-reset link is signed with the
   * same secret (`/reset/request`) but carries `purpose:"password_reset"` and no role; accepting it
   * here let mailbox control reach `/mfa/enroll` and, with the password the reset had just set,
   * replace the second factor. Only a token with no `purpose` (or `"session"`) and `role:"parent"`
   * is a bearer credential; the reset token stays valid only on `/reset/confirm`.
   */
  const requireJwt = async (req: FastifyRequest, reply: FastifyReply) => {
    try {
      await req.jwtVerify();
    } catch {
      await reply.code(401).send({ error: "unauthorized" });
      return;
    }
    const user = req.user as { sub?: string; role?: string; purpose?: string; jti?: string; iat?: number; sv?: number };
    if (!isBearerSession(user) || user.role !== "parent") {
      await reply.code(401).send({ error: "unauthorized" });
      return;
    }
    // ADR-0014 / ADR-0025: a revoked or pre-revocation-generation token is dead here too, not
    // only behind the global hook.
    if (!(await isParentSessionLive(user))) {
      await reply.code(401).send({ error: "session_revoked" });
    }
  };

  /**
   * Generate a TOTP secret for the authenticated parent and return an otpauth URL.
   *
   * First-time enrolment needs only the session (onboarding). Replacing an existing secret requires
   * re-authentication with the account password or a current TOTP code — otherwise a bearer token
   * alone would let whoever holds it rebind the second factor and lock the parent out.
   */
  app.post("/mfa/enroll", { preHandler: requireJwt, config: RL }, async (req, reply) => {
    const user = req.user as { sub: string };
    const parent = await prisma.parent.findUnique({ where: { id: user.sub } });
    if (!parent) return reply.code(404).send({ error: "parent_not_found" });

    if (parent.mfaSecret) {
      const parsed = MfaEnrollSchema.safeParse(req.body ?? {});
      if (!parsed.success) return reply.code(400).send({ error: parsed.error.flatten() });
      let reauthenticated = false;
      if (parsed.data.password) {
        try {
          reauthenticated = await argon2.verify(parent.passwordHash, parsed.data.password);
        } catch (err) {
          req.log.warn({ err }, "MFA enrol re-authentication password check failed");
        }
      }
      if (!reauthenticated && parsed.data.code) {
        reauthenticated = await verifyTotpFresh(parent.id, parent.mfaSecret, parsed.data.code);
      }
      if (!reauthenticated) return reply.code(401).send({ error: "reauth_required" });
    }

    const secret = generateTotpSecret();
    const updated = await prisma.parent.update({
      where: { id: parent.id },
      data: { mfaSecret: encryptSecret(secret) },
    });
    const otpauthUrl = `otpauth://totp/OSRA:${encodeURIComponent(updated.email)}?secret=${secret}&issuer=OSRA`;
    return { secret, otpauthUrl };
  });

  /** Verify a 6-digit TOTP code against the enrolled secret and enable MFA. */
  app.post("/mfa/verify", { preHandler: requireJwt, config: RL }, async (req, reply) => {
    const parsed = z.object({ code: z.string().regex(/^\d{6}$/) }).safeParse(req.body);
    if (!parsed.success) return reply.code(400).send({ error: parsed.error.flatten() });
    const user = req.user as { sub: string };
    const parent = await prisma.parent.findUnique({ where: { id: user.sub } });
    if (!parent?.mfaSecret) return reply.code(400).send({ error: "mfa_not_enrolled" });
    if (!(await verifyTotpFresh(parent.id, parent.mfaSecret, parsed.data.code))) {
      return reply.code(401).send({ error: "invalid_code" });
    }
    await prisma.parent.update({ where: { id: parent.id }, data: { mfaEnabled: true } });
    // Handoff item 3: enabling MFA revokes all existing sessions.
    await revokeAllRefreshTokens(parent.id);
    return { ok: true, mfaEnabled: true };
  });

  /** Issue a 15-minute password-reset token (logged to console as the email stub). */
  // NOTE: email delivery is stubbed — production would send this token via a real email
  // provider; it is printed to the server log instead.
  app.post("/reset/request", { config: RL }, async (req, reply) => {
    const parsed = z.object({ email: z.string().email().transform((e) => e.trim().toLowerCase()) }).safeParse(req.body);
    if (!parsed.success) return reply.code(400).send({ error: parsed.error.flatten() });
    const parent = await prisma.parent.findUnique({ where: { email: parsed.data.email } });
    if (parent) {
      const token = app.jwt.sign({ sub: parent.id, purpose: "password_reset" }, { expiresIn: "15m" });
      // Phase 2a: the live token goes only into the email (audit API-07: it used to be logged).
      const link = `${appPublicUrl()}/reset?token=${encodeURIComponent(token)}`;
      const result = await getEmailSender().send(passwordResetEmail(parent.email, link));
      if (!result.ok) req.log.error({ reason: result.reason }, "password reset email failed");
    }
    return { ok: true };
  });

  /** Validate a reset token and set a new password (argon2-hashed). */
  app.post("/reset/confirm", { config: RL }, async (req, reply) => {
    const parsed = z.object({ token: z.string().min(1), password: z.string().min(12) }).safeParse(req.body);
    if (!parsed.success) return reply.code(400).send({ error: parsed.error.flatten() });
    let payload: { sub: string; purpose?: string };
    try {
      payload = app.jwt.verify<{ sub: string; purpose?: string }>(parsed.data.token);
    } catch {
      return reply.code(401).send({ error: "invalid_or_expired_token" });
    }
    if (payload.purpose !== "password_reset") return reply.code(401).send({ error: "invalid_or_expired_token" });
    const passwordHash = await argon2.hash(parsed.data.password);
    try {
      await prisma.parent.update({ where: { id: payload.sub }, data: { passwordHash } });
    } catch {
      // Parent deleted between token issuance and confirmation (review API-8).
      return reply.code(404).send({ error: "account_not_found" });
    }
    // Handoff item 3: a password change revokes every existing session.
    await revokeAllRefreshTokens(payload.sub);
    return { ok: true };
  });

  /** Exchange a refresh token for a new JWT + rotated refresh token (old one invalidated). */
  app.post("/token/refresh", { config: RL }, async (req, reply) => {
    const parsed = z.object({ refreshToken: z.string().min(1) }).safeParse(req.body);
    if (!parsed.success) return reply.code(400).send({ error: parsed.error.flatten() });
    const hash = hashToken(parsed.data.refreshToken);
    const redis = getRedis();
    const raw = await redis.get(liveKey(hash)).catch(() => null);
    if (!raw) {
      // Reuse detection (handoff item 1): a consumed token presented again = theft.
      const used = await redis.get(usedKey(hash)).catch(() => null);
      if (used) {
        const parentId = await redis.get(`refresh:owner:${hash}`).catch(() => null);
        if (parentId) {
          await revokeAllRefreshTokens(parentId);
          const jti = await redis.get(`refresh:jwt:${hash}`).catch(() => null);
          if (jti) {
            await redis.set(`revoked:token:${jti}`, "1", "EX", 86400);
          }
        }
        return reply.code(401).send({ error: "refresh_token_reused" });
      }
      return reply.code(401).send({ error: "invalid_refresh_token" });
    }
    const stored = JSON.parse(raw) as { parentId: string; expiresAt: number; sv?: number };
    if (stored.expiresAt < Date.now()) {
      // Expired-but-present (the key's TTL and the stored instant can disagree by a few seconds):
      // retire it fully so the hash leaves the index too (#57).
      await retireRefreshToken(hash, stored.parentId);
      return reply.code(401).send({ error: "invalid_refresh_token" });
    }
    // #158: read the sessions version ONCE, before retiring the token and before the DB round trip,
    // then use that same value for the checks below and for the tokens minted at the end. A
    // revocation that lands after this read makes the new credentials stale (dead on use); a
    // revocation that landed before it is visible here and refuses the refresh outright. Reading the
    // version again at mint time was the TOCTOU: it let a refresh accepted before the revocation mint
    // a token stamped with the post-revocation version.
    const sv = await currentSessionVersion(stored.parentId);
    // A record without `sv` was written before #158. Its issuance time cannot be established
    // reliably (the legacy epoch is best-effort and expires after 8 days), and treating an unknown
    // version as current is exactly the fail-open this change removes. Force a re-login instead:
    // one authentication event per parent on deploy, once, against silent session resurrection.
    if (typeof stored.sv !== "number" || stored.sv < sv) {
      return reply.code(401).send({ error: "session_revoked" });
    }
    // Rotation: mark the presented token consumed before issuing new credentials.
    await retireRefreshToken(hash, stored.parentId);
    await redis.set(`refresh:owner:${hash}`, stored.parentId, "EX", Math.floor(REFRESH_TTL_MS / 1000));
    const parent = await prisma.parent.findUnique({ where: { id: stored.parentId } });
    if (!parent) return reply.code(401).send({ error: "invalid_refresh_token" });
    const { token, jti } = await signParentToken(app, parent, { sv });
    // Theft response: if the token we just consumed is ever presented again, the SESSION IT ROTATED
    // INTO (this jti) is what must die — `refresh:jwt:<old hash>` is how the reuse path finds it.
    await redis.set(`refresh:jwt:${hash}`, jti, "EX", Math.floor(REFRESH_TTL_MS / 1000));
    return { token, refreshToken: await issueRefreshToken(parent.id, sv, jti) };
  });

  /** Revoke a single refresh token (logout; always 200 — handoff item 2). */
  app.post("/logout", { config: RL }, async (req) => {
    const parsed = z.object({ refreshToken: z.string().min(1) }).safeParse(req.body);
    if (parsed.success) {
      const hash = hashToken(parsed.data.refreshToken);
      // Read the owner BEFORE deleting the live key — it is the only place the parentId lives for a
      // token that has never been rotated (#57).
      const redis = getRedis();
      const raw = await redis.get(liveKey(hash)).catch(() => null);
      let parentId: string | null = null;
      let jti: string | null = null;
      try {
        const rec = raw ? (JSON.parse(raw) as { parentId?: string; jti?: string | null }) : null;
        parentId = rec?.parentId ?? null;
        jti = rec?.jti ?? null;
      } catch { parentId = null; }
      await retireRefreshToken(hash, parentId);
      // ADR-0014: logging out a session also kills the access token that was issued with it.
      if (jti) await redis.set(`revoked:token:${jti}`, "1", "EX", 8 * 24 * 3600).catch(() => {});
    }
    return { ok: true };
  });

  /** Revoke every refresh token of the authenticated parent (handoff item 2). */
  app.post("/logout-all", { preHandler: requireJwt, config: RL }, async (req) => {
    const user = req.user as { sub: string };
    await revokeAllRefreshTokens(user.sub);
    return { ok: true };
  });
}
