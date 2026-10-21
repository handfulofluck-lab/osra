import type { FastifyInstance, FastifyReply, FastifyRequest } from "fastify";
import { createHash, randomBytes, timingSafeEqual } from "node:crypto";
import argon2 from "argon2";
import { z } from "zod";
import { prisma } from "../db.js";
import { appPublicUrl, getEmailSender } from "../lib/email/index.js";
import { mfaRecoveredEmail, passwordResetEmail } from "../lib/email/templates.js";
import { generateTotpSecret, totpAtCounter } from "../lib/totp.js";
import { getRedis } from "../redis.js";
import { isValidTimeZone } from "../lib/digestSchedule.js";
import {
  RECOVERY_CODE_COUNT,
  RECOVERY_CODE_LENGTH,
  RECOVERY_CODE_TTL_MINUTES,
  formatRecoveryCode,
  generateRecoveryCodeBatch,
  hashRecoveryCode,
  normaliseRecoveryCode,
} from "../lib/mfaRecovery.js";
import { currentSessionVersion, invalidateSessionsBefore, isBearerSession, isParentSessionLive, newJti, signParentToken } from "../lib/sessions.js";
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
 * ADR-0023: the same proof of parentage that replaces a TOTP secret also guards replacing the codes
 * that survive it — a stolen session alone must not hand itself a fresh batch.
 */
const MfaRecoveryCodeRequestSchema = MfaEnrollSchema;

/** ADR-0023: recovery takes the account password and one unused code, nothing else. */
const MfaRecoverSchema = z.object({
  email: z.string().email().transform((e) => e.trim().toLowerCase()),
  password: z.string().min(1).max(256),
  code: z.string().min(1).max(64),
});

/**
 * A password hash to verify against when the email is unknown (ADR-0023): without it, an unknown
 * address answers in microseconds while a known one spends argon2's ~100 ms, which is an
 * enumeration oracle even though the body is identical. Computed once, lazily, with random input.
 */
let dummyPasswordHash: Promise<string> | null = null;
const unknownParentPasswordHash = (): Promise<string> =>
  (dummyPasswordHash ??= argon2.hash(randomBytes(16).toString("hex")));

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
    //
    // #183: `mfaEnabled` is the account's policy and survives a recovery; `mfaSecret` is the bound
    // factor and does not. Between the two, a correct password reaches an account with nothing to
    // ask a code from — and it gets no session: not a token, not a refresh record, and deliberately
    // **not** a recovery token either. Minting one here would hand a stolen password the
    // re-enrolment credential it needs, which is the same takeover this check removes, two calls
    // later. The 15-minute token from `/mfa/recover` (password + an unused code) is the only way in.
    if (parent.mfaEnabled) {
      if (!parent.mfaSecret) return reply.code(401).send({ error: "mfa_reenroll_required" });
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

  // --- ADR-0023: one-time MFA recovery codes ---------------------------------------------------
  // The recovery token is NOT a session. It is minted only by `/mfa/recover`, lives 15 minutes in
  // Redis under `mfa:recovery:<jti>`, carries no `familyId` and no `role`, and is accepted only by
  // `/mfa/enroll` and `/mfa/verify` while the account is still short of a complete second factor
  // (#183: `mfaEnabled` stays true through a recovery, so completion is a live batch, not the flag).
  // Every other route goes through `requireJwt`, whose #146/#147 rule (`isBearerSession` +
  // `role:"parent"`) rejects the purpose claim untouched.
  const RECOVERY_TTL_SECONDS = RECOVERY_CODE_TTL_MINUTES * 60;
  const recoveryKey = (jti: string) => `mfa:recovery:${jti}`;

  /**
   * Has this account finished the recovery and bound a new factor? The routes that write a batch of
   * unused codes are `/mfa/verify` (a completed enrolment) and `/mfa/recovery-codes` (an explicit
   * regeneration), and `/mfa/recover` deletes the old batch — so a recovery token can only exist
   * while this is false, and "a live batch exists" is the durable completion state. It is the
   * database half of the token boundary; the Redis `jti` delete in `/mfa/verify` is the first half,
   * so a store failure cannot keep a spent token alive.
   */
  const holdsLiveRecoveryBatch = async (parentId: string): Promise<boolean> =>
    (await prisma.parentMfaRecoveryCode.count({ where: { parentId, usedAt: null } })) > 0;

  /** Ten fresh codes plus the rows that store their hashes — the plaintext exists only in `codes`. */
  const newRecoveryCodeRows = (parentId: string, issuedAt: Date) => {
    const codes = generateRecoveryCodeBatch(RECOVERY_CODE_COUNT);
    return {
      codes,
      rows: codes.map((code) => ({ parentId, codeHash: hashRecoveryCode(code), createdAt: issuedAt })),
    };
  };

  /**
   * #139's rule, shared by the two routes that can replace a second factor or the codes guarding it:
   * the account password (preferred) or a code from the current authenticator. Only meaningful when
   * a secret exists — a first enrolment is onboarding, not a replacement.
   */
  const provesParent = async (
    req: FastifyRequest,
    parent: { id: string; passwordHash: string; mfaSecret: string | null },
    data: { password?: string; code?: string },
  ): Promise<boolean> => {
    if (data.password) {
      try {
        if (await argon2.verify(parent.passwordHash, data.password)) return true;
      } catch (err) {
        req.log.warn({ err }, "MFA re-authentication password check failed");
      }
    }
    if (data.code && parent.mfaSecret) return verifyTotpFresh(parent.id, parent.mfaSecret, data.code);
    return false;
  };

  /**
   * A live parent session OR a live `mfa_recovery` token, for the two enrolment routes only.
   *
   * The session half is #146/#147 unchanged. The recovery half is deliberately narrow: signature,
   * `purpose === "mfa_recovery"`, and a `jti` the store still knows and still attributes to this
   * parent. The store check fails closed even outside production (`/mfa/enroll` and `/mfa/verify`
   * are 15-minute high-value surfaces, not a session read), and the handlers additionally refuse
   * the token once the account holds a live batch again (#183 — `mfaEnabled` no longer says that).
   */
  const requireParentOrMfaRecovery = async (req: FastifyRequest, reply: FastifyReply) => {
    try {
      await req.jwtVerify();
    } catch {
      await reply.code(401).send({ error: "unauthorized" });
      return;
    }
    const user = req.user as { sub?: string; role?: string; purpose?: string; jti?: string; iat?: number; sv?: number };
    if (isBearerSession(user) && user.role === "parent") {
      if (!(await isParentSessionLive(user))) {
        await reply.code(401).send({ error: "session_revoked" });
      }
      return;
    }
    if (user.purpose === "mfa_recovery" && user.sub && user.jti) {
      let owner: string | null = null;
      try {
        owner = await getRedis().get(recoveryKey(user.jti));
      } catch (err) {
        req.log.error({ err }, "[security] MFA recovery store unreachable — rejecting recovery token");
      }
      if (owner === user.sub) return;
    }
    await reply.code(401).send({ error: "unauthorized" });
  };

  /**
   * Generate a TOTP secret for the authenticated parent and return an otpauth URL.
   *
   * First-time enrolment needs only the session (onboarding). Replacing an existing secret requires
   * re-authentication with the account password or a current TOTP code — otherwise a bearer token
   * alone would let whoever holds it rebind the second factor and lock the parent out.
   */
  app.post("/mfa/enroll", { preHandler: requireParentOrMfaRecovery, config: RL }, async (req, reply) => {
    const user = req.user as { sub: string; purpose?: string };
    const parent = await prisma.parent.findUnique({ where: { id: user.sub } });
    if (!parent) return reply.code(404).send({ error: "parent_not_found" });

    // ADR-0023 decision 3, as amended by #183: a recovery token may bind the missing factor, but its
    // job ends when the account holds a live batch again — otherwise a 15-minute token would outlive
    // the recovery it served. `mfaEnabled` cannot stand in for that any more (it stays true through
    // a recovery), so this asks for the durable completion state instead.
    if (user.purpose === "mfa_recovery" && (await holdsLiveRecoveryBatch(parent.id))) {
      return reply.code(401).send({ error: "unauthorized" });
    }

    if (parent.mfaSecret && user.purpose !== "mfa_recovery") {
      // A recovery token has already proved password + a one-time code at `/mfa/recover`, and it is
      // accepted here only before a new batch exists — so replacing an *unverified* secret with it
      // (a retry after a bad scan, #183) is not the replacement #139 guards against.
      const parsed = MfaEnrollSchema.safeParse(req.body ?? {});
      if (!parsed.success) return reply.code(400).send({ error: parsed.error.flatten() });
      if (!(await provesParent(req, parent, parsed.data))) {
        return reply.code(401).send({ error: "reauth_required" });
      }
    }

    const secret = generateTotpSecret();
    const updated = await prisma.parent.update({
      where: { id: parent.id },
      data: { mfaSecret: encryptSecret(secret) },
    });
    const otpauthUrl = `otpauth://totp/OSRA:${encodeURIComponent(updated.email)}?secret=${secret}&issuer=OSRA`;
    return { secret, otpauthUrl };
  });

  /**
   * Verify a 6-digit TOTP code against the enrolled secret, enable MFA, and issue the account's
   * one-time recovery codes (ADR-0023). This response is the **only** time the plaintext codes
   * exist: the rows hold SHA-256 hashes, no route reads them back, and a replacement batch is a
   * destructive overwrite.
   */
  app.post("/mfa/verify", { preHandler: requireParentOrMfaRecovery, config: RL }, async (req, reply) => {
    const parsed = z.object({ code: z.string().regex(/^\d{6}$/) }).safeParse(req.body);
    if (!parsed.success) return reply.code(400).send({ error: parsed.error.flatten() });
    const user = req.user as { sub: string; purpose?: string; jti?: string };
    const parent = await prisma.parent.findUnique({ where: { id: user.sub } });
    if (!parent?.mfaSecret) return reply.code(400).send({ error: "mfa_not_enrolled" });
    // #183: the token's authority ends with the recovery, and a completed recovery is a live batch.
    if (user.purpose === "mfa_recovery" && (await holdsLiveRecoveryBatch(parent.id))) {
      return reply.code(401).send({ error: "unauthorized" });
    }
    if (!(await verifyTotpFresh(parent.id, parent.mfaSecret, parsed.data.code))) {
      return reply.code(401).send({ error: "invalid_code" });
    }
    const issuedAt = new Date();
    const { codes, rows } = newRecoveryCodeRows(parent.id, issuedAt);
    await prisma.$transaction(async (tx) => {
      await tx.parent.update({ where: { id: parent.id }, data: { mfaEnabled: true } });
      // The previous batch belonged to the previous secret: it goes, even on a re-enrolment.
      await tx.parentMfaRecoveryCode.deleteMany({ where: { parentId: parent.id } });
      await tx.parentMfaRecoveryCode.createMany({ data: rows });
    });
    // The recovery token has done its job. The batch check above already refuses it once a new batch
    // exists, so the token is dead twice over and a failed delete only shortens the window.
    if (user.purpose === "mfa_recovery" && user.jti) {
      await getRedis().del(recoveryKey(user.jti)).catch(() => undefined);
    }
    // Handoff item 3: enabling MFA revokes all existing sessions.
    await revokeAllRefreshTokens(parent.id);
    return {
      ok: true,
      mfaEnabled: true,
      recoveryCodes: codes.map(formatRecoveryCode),
      recoveryCodesIssuedAt: issuedAt.toISOString(),
    };
  });

  /**
   * Issue a fresh batch of one-time recovery codes (ADR-0023).
   *
   * Generation and regeneration are the same operation: a batch exists only as hashes, so "show me
   * the codes again" is not possible by design — the only way to get codes is to replace them. When
   * a secret exists this requires the #139 proof of parentage, because it invalidates the parent's
   * saved list; a first batch for an account with no secret needs only the session, exactly as a
   * first enrolment does.
   */
  app.post("/mfa/recovery-codes", { preHandler: requireJwt, config: RL }, async (req, reply) => {
    const user = req.user as { sub: string };
    const parent = await prisma.parent.findUnique({ where: { id: user.sub } });
    if (!parent) return reply.code(404).send({ error: "parent_not_found" });
    if (parent.mfaSecret) {
      const parsed = MfaRecoveryCodeRequestSchema.safeParse(req.body ?? {});
      if (!parsed.success) return reply.code(400).send({ error: parsed.error.flatten() });
      if (!(await provesParent(req, parent, parsed.data))) {
        return reply.code(401).send({ error: "reauth_required" });
      }
    }
    const issuedAt = new Date();
    const { codes, rows } = newRecoveryCodeRows(parent.id, issuedAt);
    await prisma.$transaction(async (tx) => {
      await tx.parentMfaRecoveryCode.deleteMany({ where: { parentId: parent.id } });
      await tx.parentMfaRecoveryCode.createMany({ data: rows });
    });
    return { recoveryCodes: codes.map(formatRecoveryCode), recoveryCodesIssuedAt: issuedAt.toISOString() };
  });

  /**
   * Recover the account after losing the authenticator (ADR-0023 decision 2, as amended by #183).
   *
   * Password + one unused code, and the result is a 15-minute purpose-scoped token — **not** a
   * session. The authenticator is cleared because the old one is presumed gone, the used code is
   * spent, the rest of the batch is deleted (a stolen list is bounded to one use), every session is
   * revoked, and the account owner is notified. Enrolment and verification must happen before the
   * parent can read family data again — and before then `POST /login` answers
   * `401 mfa_reenroll_required` to the password alone, because the policy stays on (`mfaEnabled`)
   * while the factor does not (`mfaSecret`). That is the difference between this route and a
   * password reset: it removes a broken factor, it does not downgrade the account.
   *
   * Every failure is the same `401 invalid_recovery` — unknown address, wrong password, wrong or
   * spent code, MFA not enabled — so the endpoint is not an account or MFA state oracle.
   */
  app.post("/mfa/recover", { config: RL }, async (req, reply) => {
    const parsed = MfaRecoverSchema.safeParse(req.body);
    if (!parsed.success) return reply.code(400).send({ error: parsed.error.flatten() });
    const parent = await prisma.parent.findUnique({ where: { email: parsed.data.email } });
    // Verify a hash even when the address is unknown, so the work done (and the time taken) does
    // not distinguish "no such account" from "wrong password".
    const passwordHash = parent?.passwordHash ?? (await unknownParentPasswordHash());
    const passwordOk = await argon2.verify(passwordHash, parsed.data.password).catch(() => false);
    if (!parent || !passwordOk || !parent.mfaEnabled) {
      return reply.code(401).send({ error: "invalid_recovery" });
    }

    const normalised = normaliseRecoveryCode(parsed.data.code);
    if (normalised.length !== RECOVERY_CODE_LENGTH) {
      return reply.code(401).send({ error: "invalid_recovery" });
    }
    const candidate = await prisma.parentMfaRecoveryCode.findFirst({
      where: { parentId: parent.id, codeHash: hashRecoveryCode(normalised) },
    });
    if (!candidate) return reply.code(401).send({ error: "invalid_recovery" });

    const usedAt = new Date();
    const consumed = await prisma.$transaction(async (tx) => {
      // One-time use is this count: of two concurrent requests with the same code, exactly one can
      // flip `usedAt` from null, so the loser never reaches the half that clears MFA.
      const claimed = await tx.parentMfaRecoveryCode.updateMany({
        where: { id: candidate.id, usedAt: null },
        data: { usedAt },
      });
      if (claimed.count !== 1) return false;
      // The used row is the record that the batch was spent; its siblings are dead credentials.
      await tx.parentMfaRecoveryCode.deleteMany({
        where: { parentId: parent.id, id: { not: candidate.id } },
      });
      // #183: only the factor goes. `mfaEnabled` is the account's second-factor policy and a recovery
      // does not turn it off — clearing it here is what let a stolen password produce a full session
      // on the next `/login` and made the purpose-scoped token below restrict nothing.
      await tx.parent.update({ where: { id: parent.id }, data: { mfaSecret: null } });
      return true;
    });
    if (!consumed) return reply.code(401).send({ error: "invalid_recovery" });

    // A lost device must not keep a live session: revoking also bumps the sessions version, so
    // access tokens die with the refresh tokens (ADR-0025).
    await revokeAllRefreshTokens(parent.id);

    const jti = randomBytes(16).toString("hex");
    const recoveryToken = app.jwt.sign(
      { sub: parent.id, purpose: "mfa_recovery", jti },
      { expiresIn: `${RECOVERY_CODE_TTL_MINUTES}m` },
    );
    await getRedis().set(recoveryKey(jti), parent.id, "EX", RECOVERY_TTL_SECONDS);

    const notice = await getEmailSender().send(mfaRecoveredEmail(parent.email));
    if (!notice.ok) req.log.error({ reason: notice.reason }, "MFA recovery notice email failed");

    return { recoveryToken };
  });

  // --- #167: a password-reset link is single-use ------------------------------------------------
  // `reset:<jti>` is the record `GETDEL` consumes (the token's `jti` is its only identity);
  // `reset:latest:<parentId>` names the one jti still honoured, so a second /reset/request kills the
  // first. Both live 15 minutes, the token's own lifetime.
  const RESET_TTL_SECONDS = 15 * 60;
  const resetKey = (jti: string) => `reset:${jti}`;
  const resetLatestKey = (parentId: string) => `reset:latest:${parentId}`;

  /**
   * Put a consumed `reset:<jti>` record back after a failure past the point of consumption.
   *
   * #162 made a 5xx from the counter bump retryable with the same token, and that is load-bearing:
   * the client retries a failed reset instead of asking for a new link. Because the single-use
   * consume runs *before* the work, the record must be restored here or the retry would answer 401.
   * The TTL is the token's own remaining lifetime (`exp - now`), not a fresh 900 — a restored record
   * must never outlive the signed token it stands for. If the token has already expired there is
   * nothing to restore. Do not delete this as dead code.
   */
  const restoreResetToken = async (parentId: string, jti: string, exp: number | undefined, req: FastifyRequest): Promise<void> => {
    if (typeof exp !== "number") return;
    const remaining = exp - Math.floor(Date.now() / 1000);
    if (remaining <= 0) return;
    await getRedis().set(resetKey(jti), parentId, "EX", remaining).catch((err) => {
      req.log.error({ err }, "[security] could not restore a consumed reset token; the client's retry will need a new link");
    });
  };

  /** Issue a 15-minute password-reset token (logged to console as the email stub). */
  // NOTE: email delivery is stubbed — production would send this token via a real email
  // provider; it is printed to the server log instead.
  app.post("/reset/request", { config: RL }, async (req, reply) => {
    const parsed = z.object({ email: z.string().email().transform((e) => e.trim().toLowerCase()) }).safeParse(req.body);
    if (!parsed.success) return reply.code(400).send({ error: parsed.error.flatten() });
    const parent = await prisma.parent.findUnique({ where: { email: parsed.data.email } });
    if (parent) {
      const jti = newJti();
      const token = app.jwt.sign({ sub: parent.id, purpose: "password_reset", jti }, { expiresIn: "15m" });
      const redis = getRedis();
      // Issuing a link that can never be redeemed is worse than a 5xx, so both writes are awaited
      // before the email goes out. Superseding is the `latest` write alone: the older key stays until
      // its TTL, but no confirm will honour it.
      await redis.set(resetKey(jti), parent.id, "EX", RESET_TTL_SECONDS);
      await redis.set(resetLatestKey(parent.id), jti, "EX", RESET_TTL_SECONDS);
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
    let payload: { sub: string; purpose?: string; jti?: string; exp?: number };
    try {
      payload = app.jwt.verify<{ sub: string; purpose?: string; jti?: string; exp?: number }>(parsed.data.token);
    } catch {
      return reply.code(401).send({ error: "invalid_or_expired_token" });
    }
    // A token minted before #167 has no `jti` and no store record: it is refused like a spent link,
    // the same one-re-login migration cost ADR-0025 accepted for legacy refresh records.
    if (payload.purpose !== "password_reset" || !payload.jti) {
      return reply.code(401).send({ error: "invalid_or_expired_token" });
    }
    const redis = getRedis();
    // Atomic single use, before the hash is computed: GETDEL returns the owner exactly once, so of
    // two concurrent confirmations of the same link only one can proceed. A missing key is a spent,
    // superseded or expired token.
    let owner: string | null;
    try {
      owner = await redis.getdel(resetKey(payload.jti));
    } catch (err) {
      // Not a spent link but an unreachable store: report a 5xx, which the #162 retry contract
      // already treats as transient, instead of telling the parent the link is dead.
      req.log.error({ err }, "[security] reset-token store unreachable — refusing reset confirm");
      throw err;
    }
    if (owner !== payload.sub) return reply.code(401).send({ error: "invalid_or_expired_token" });
    // Superseded by a newer request (read after the consume: a request that lands between the two
    // still wins, and the older token stays dead either way). A store error here is not "superseded":
    // put the record back and fail as a 5xx, so the client's retry is not turned into a spent link.
    let latest: string | null;
    try {
      latest = await redis.get(resetLatestKey(payload.sub));
    } catch (err) {
      await restoreResetToken(payload.sub, payload.jti, payload.exp, req);
      throw err;
    }
    if (latest !== payload.jti) return reply.code(401).send({ error: "invalid_or_expired_token" });

    let passwordHash: string;
    try {
      passwordHash = await argon2.hash(parsed.data.password);
    } catch (err) {
      await restoreResetToken(payload.sub, payload.jti, payload.exp, req);
      throw err;
    }
    try {
      await prisma.parent.update({ where: { id: payload.sub }, data: { passwordHash } });
    } catch (err) {
      // Review API-8 answered 404 for "parent deleted between issuance and confirmation", and that
      // answer is right for a *missing* parent — but it was used for every failure, so a transient
      // database error told the client its account was gone and the retry #162 promised never came.
      // Distinguish them by re-reading: gone -> 404 with the link left dead (there is nobody to
      // restore it for); still there -> restore the record and fail 5xx, which is transient.
      const stillExists = await prisma.parent.findUnique({ where: { id: payload.sub }, select: { id: true } }).catch(() => null);
      if (!stillExists) return reply.code(404).send({ error: "account_not_found" });
      await restoreResetToken(payload.sub, payload.jti, payload.exp, req);
      req.log.error({ err }, "[security] password update failed after the reset token was consumed; the token was restored for the retry");
      throw err;
    }
    // Handoff item 3: a password change revokes every existing session. This must not be reported as
    // success when it throws (#162/#135: a revocation that did not happen is a 5xx), and the restored
    // token is what makes the client's retry succeed.
    try {
      await revokeAllRefreshTokens(payload.sub);
    } catch (err) {
      await restoreResetToken(payload.sub, payload.jti, payload.exp, req);
      throw err;
    }
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
