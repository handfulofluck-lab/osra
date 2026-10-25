import type { FastifyInstance, FastifyReply, FastifyRequest } from "fastify";
import { createHash, randomBytes, timingSafeEqual } from "node:crypto";
import argon2 from "argon2";
import { Prisma } from "@prisma/client";
import type { MfaResetRequest as MfaResetRequestRow } from "@prisma/client";
import { z } from "zod";
import { prisma } from "../db.js";
import { appPublicUrl, emailConfigured, getEmailSender } from "../lib/email/index.js";
import { mfaRecoveredEmail, passwordResetEmail } from "../lib/email/templates.js";
import { enqueueDeviceCommand } from "../lib/deviceCommands.js";
import {
  MFA_RESET_CODE_TTL_SECONDS,
  MFA_RESET_MAILBOX_TTL_SECONDS,
  MFA_RESET_MAX_CODE_ATTEMPTS,
  MFA_RESET_MAX_PER_WINDOW,
  MFA_RESET_REQUEST_WINDOW_MS,
  MFA_RESET_WITNESS_DEADLINE_MS,
  OPEN_RESET_STATES,
  clearResetCodePayloads,
  generateResetCode,
  hashResetCode,
  resetCodeMatches,
  resetWindowEndsAt,
} from "../lib/mfaReset.js";
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
import { currentSessionVersion, invalidateSessionsBefore, isBearerSession, isParentSessionLive, newJti, revokeTokenOnce, signParentToken } from "../lib/sessions.js";
import { decryptSecret, encryptSecret, isEncryptedSecret } from "../lib/secretVault.js";
import { AUTH_RATE_LIMIT } from "../lib/rateLimits.js";

const RegisterSchema = z.object({
  email: z.string().email().transform((e) => e.trim().toLowerCase()),
  password: z.string().min(12),
  // Roadmap 2.7 (osra-security#2): the name appears in a digest subject and body, so it is bounded at
  // the write. The templates clip as well — a row stored before this bound cannot stretch a send.
  displayName: z.string().min(1).max(80),
  familyName: z.string().min(1).max(80),
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
  const RL = { rateLimit: AUTH_RATE_LIMIT };
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
    // ADR-0031 decision 3: a successful sign-in by the parent is the main defence of a pending MFA
    // reset — whoever can sign in is not locked out, so the request was not theirs. It is cancelled
    // here, before any session is minted, and `complete` refuses a cancelled request. This covers a
    // request still waiting for its mailbox click as well as one inside the 72-hour window: a parent
    // who signs in has no reason to keep either alive.
    // #305 review: a cancelled request must not keep a live code on the child's phone for its
    // remaining 10 minutes. The ids are read first because `updateMany` does not return them.
    const openBeforeSignIn = (await prisma.mfaResetRequest.findMany({
      where: { parentId: parent.id, state: { in: [...OPEN_RESET_STATES] } },
      select: { id: true },
    })) ?? [];
    await prisma.mfaResetRequest.updateMany({
      where: { parentId: parent.id, state: { in: [...OPEN_RESET_STATES] } },
      data: { state: "cancelled_by_signin", cancelledReason: "signin", outcomeAt: new Date() },
    });
    for (const open of openBeforeSignIn) {
      await clearResetCodePayloads(open.id).catch((err) =>
        req.log.warn({ err, requestId: open.id }, "[mfa-reset] could not clear the code of a cancelled request"),
      );
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
    // #199: only an unused row leads to revocation. A spent row still matches its hash, and without
    // this filter a replay would reach the revocation below and answer 401 — a logout lever for
    // anyone holding the password and a spent code.
    const candidate = await prisma.parentMfaRecoveryCode.findFirst({
      where: { parentId: parent.id, codeHash: hashRecoveryCode(normalised), usedAt: null },
    });
    if (!candidate) return reply.code(401).send({ error: "invalid_recovery" });

    // #199 item 3: the recovery token's Redis record is written *before* anything is spent, for the
    // same reason the revocation below moved earlier. Registering it after the commit left an
    // identical lockout: a Redis failure there answered 5xx with the code claimed, the siblings
    // deleted, `mfaSecret` cleared and no token to show for it. Registering first costs one entry
    // that a lost race deletes (below) and that expires on its own if the process dies.
    // Signing happens after the commit because it does no I/O and must not exist for a rollback.
    const jti = randomBytes(16).toString("hex");
    await getRedis().set(recoveryKey(jti), parent.id, "EX", RECOVERY_TTL_SECONDS);

    // #199: revoke *before* the code is consumed, not after the commit. `revokeAllRefreshTokens`
    // bumps the sessions version, and that bump is deliberately not best-effort (sessions.ts:113-114):
    // if Redis rejects it, this throws and the request answers 5xx with the code still unspent, so
    // the parent retries instead of being locked out with the code gone. The other failure direction
    // is the safe one: a revocation that succeeds and a transaction that then fails leaves every
    // session dead and the code usable.
    // A lost device must not keep a live session: revoking also bumps the sessions version, so
    // access tokens die with the refresh tokens (ADR-0025).
    await revokeAllRefreshTokens(parent.id);

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
    if (!consumed) {
      // Lost the race (or the batch vanished): the record registered above names no token, because
      // none was signed, so deleting it is tidiness rather than correctness — and a failure here must
      // not turn a 401 into a 5xx.
      await getRedis().del(recoveryKey(jti)).catch(() => {});
      return reply.code(401).send({ error: "invalid_recovery" });
    }

    const recoveryToken = app.jwt.sign(
      { sub: parent.id, purpose: "mfa_recovery", jti },
      { expiresIn: `${RECOVERY_CODE_TTL_MINUTES}m` },
    );

    const notice = await getEmailSender().send(mfaRecoveredEmail(parent.email));
    if (!notice.ok) req.log.error({ reason: notice.reason }, "MFA recovery notice email failed");

    return { recoveryToken };
  });

  // --- ADR-0031: MFA reset with a family witness and a 72-hour window ----------------------------
  // The route for a parent who has lost the authenticator AND every recovery code. It ends in the
  // same purpose-scoped `mfa_recovery` token `/mfa/recover` issues (decision 5), so there is exactly
  // one path to "MFA cleared" and one forced re-enrolment after it. Four factors in order: password,
  // mailbox, a family witness (a paired child device or another owner/co-parent), then a 72-hour
  // window. Nothing here reads, stores or logs the plaintext device code except the `show_reset_code`
  // payload itself, which the device command queue clears (claim 6).
  //
  // Email and push templates are deliberately not built with this API half: the send points are
  // `[mfa-reset] ... hook` log lines, and the 24-hour reminder has no sender at all (the expiry job
  // says so). The parent-app and Android screens are out of scope too.
  const resetConfirmKey = (jti: string) => `mfa:reset:confirm:${jti}`;
  const echoResetTokens = !emailConfigured() && process.env.NODE_ENV !== "production";

  /** The two witnesses decision 6 asks about, counted for a family before anything is written. */
  const familyWitnesses = async (familyId: string, parentId: string) => {
    const [devices, parents] = await Promise.all([
      prisma.device.count({ where: { child: { familyId } } }),
      prisma.parent.count({ where: { familyId, id: { not: parentId }, role: { in: ["owner", "co-parent"] } } }),
    ]);
    return { devices, parents, any: devices > 0 || parents > 0 };
  };

  /**
   * The shared second half of the witness step: whichever witness passed, every session of the parent
   * being reset dies and the 72-hour window opens (claim 2).
   *
   * The revocation runs before the state write and is not best-effort — the same ordering and reasoning
   * as `/mfa/recover` (#199): if it throws, the request stays where it was and the parent retries,
   * instead of a window opening with a live session still signed in.
   */
  const passWitness = async (
    request: { id: string; parentId: string },
    witness: { kind: "device" | "parent"; ref: string | null },
    req: FastifyRequest,
  ): Promise<Date | null> => {
    await revokeAllRefreshTokens(request.parentId);
    const witnessAt = new Date();
    const windowEndsAt = resetWindowEndsAt(witnessAt);
    const claimed = await prisma.mfaResetRequest.updateMany({
      where: { id: request.id, state: "mailbox_confirmed" },
      data: { state: "witness_passed", witnessKind: witness.kind, witnessRef: witness.ref, witnessAt, windowEndsAt },
    });
    if (claimed.count !== 1) return null;
    // The code has done its job; nothing in the command queue may keep it.
    await clearResetCodePayloads(request.id).catch((err) =>
      req.log.warn({ err }, "[mfa-reset] could not clear the device code payload after the witness"),
    );
    return windowEndsAt;
  };

  /**
   * Ask for a reset: `{email, password}`, with `/login`'s rate limit and `/login`'s refusal (claim 1a).
   *
   * Nothing is sent to a child device here — not even a wake-up — because the mailbox step has not
   * happened yet (claim 1b). Nothing is written for a family with no witness (claim 7).
   *
   * A `requested` or `mailbox_confirmed` request of the same parent is superseded rather than answered
   * with `reset_already_pending` (amendment 2026-10-22, gap 3); a `witness_passed` one still blocks.
   */
  app.post("/mfa/reset/request", { config: RL }, async (req, reply) => {
    const parsed = z
      .object({
        email: z.string().email().transform((e) => e.trim().toLowerCase()),
        password: z.string().min(1).max(256),
      })
      .safeParse(req.body);
    if (!parsed.success) return reply.code(400).send({ error: parsed.error.flatten() });
    const parent = await prisma.parent.findUnique({ where: { email: parsed.data.email } });
    // The same unknown-address handling as /login: verify against a dummy hash so timing does not
    // distinguish the two, and answer one refusal.
    const passwordHash = parent?.passwordHash ?? (await unknownParentPasswordHash());
    const passwordOk = await argon2.verify(passwordHash, parsed.data.password).catch(() => false);
    if (!parent || !passwordOk) return reply.code(401).send({ error: "invalid_credentials" });
    // Nothing to reset: /login already works for an account without a second factor, and this route
    // must not become a way to clear one that is off.
    if (!parent.mfaEnabled) return reply.code(409).send({ error: "mfa_not_enabled" });

    const witnesses = await familyWitnesses(parent.familyId, parent.id);
    // Decision 6 / claim 7: refuse before the first write, so the refusal leaves no row, no email and
    // no command. Only the route's own rate-limit counter is touched.
    if (!witnesses.any) return reply.code(409).send({ error: "no_witness" });

    const open: Array<{ id: string; state: string }> = await prisma.mfaResetRequest.findMany({
      where: { parentId: parent.id, state: { in: [...OPEN_RESET_STATES] } },
      select: { id: true, state: true },
    });
    // A request whose witness already passed holds a 72-hour window nobody may overwrite: replacing it
    // would let a second `request` restart a clock a co-parent has already approved.
    if (open.some((request) => request.state === "witness_passed")) {
      return reply.code(409).send({ error: "reset_already_pending" });
    }
    // The limit is counted before anything is superseded: a request that is about to be refused as the
    // fourth in 30 days must not first expire the open one it then cannot replace. Rows are never
    // deleted by a supersede, so a superseded attempt still counts (decision 7, three per 30 days).
    const recent = await prisma.mfaResetRequest.count({
      where: { parentId: parent.id, createdAt: { gt: new Date(Date.now() - MFA_RESET_REQUEST_WINDOW_MS) } },
    });
    if (recent >= MFA_RESET_MAX_PER_WINDOW) return reply.code(429).send({ error: "reset_limit_reached" });

    // Amendment 2026-10-22, gap 3: a request the parent cannot finish is replaceable, not a dead end.
    // Reaching a child's phone with the code inside its 10 minutes can fail; the row used to sit in
    // `mailbox_confirmed` answering `reset_already_pending` until the 24-hour sweep, having already
    // spent one of the three attempts. It is superseded here — `expired`, `outcomeAt` now, its code
    // cleared from the child's phone — and the attempt keeps counting.
    const superseded = open.filter((request) => request.state === "requested" || request.state === "mailbox_confirmed");
    if (superseded.length > 0) {
      await prisma.mfaResetRequest.updateMany({
        where: { parentId: parent.id, state: { in: ["requested", "mailbox_confirmed"] } },
        data: { state: "expired", outcomeAt: new Date() },
      });
      // A superseded request must not keep a live code on the child's phone for its remaining minutes.
      for (const request of superseded) {
        await clearResetCodePayloads(request.id).catch((err) =>
          req.log.warn({ err, requestId: request.id }, "[mfa-reset] could not clear the code of a superseded request"),
        );
      }
    }

    const row = await prisma.mfaResetRequest.create({
      data: { parentId: parent.id, familyId: parent.familyId, state: "requested" },
    });
    // The mailbox link: a JWT naming this request, plus the Redis record that makes it single-use and
    // 30 minutes long. It is not a session and no route accepts it as one (#146's rule).
    const jti = newJti();
    const token = app.jwt.sign(
      { sub: parent.id, purpose: "mfa_reset_confirm", jti },
      { expiresIn: `${MFA_RESET_MAILBOX_TTL_SECONDS / 60}m` },
    );
    await getRedis().set(resetConfirmKey(jti), `${row.id}|${parent.id}`, "EX", MFA_RESET_MAILBOX_TTL_SECONDS);
    const cancelToken = app.jwt.sign(
      { sub: parent.id, purpose: "mfa_reset_cancel", requestId: row.id },
      { expiresIn: "7d" },
    );
    const linkBase = `${appPublicUrl()}/mfa/reset`;
    const link = `${linkBase}/confirm?token=${encodeURIComponent(token)}`;
    const cancelLink = `${linkBase}/cancel?token=${encodeURIComponent(cancelToken)}`;
    // Email hook, templates deferred (see CHANGELOG.d/2026-10-22-mfa-reset-api.md). In dev and test the
    // link is logged so the flow can be walked by hand; in production only the request id is logged,
    // because a live single-use link belongs in the mailbox and nowhere else.
    if (process.env.NODE_ENV !== "production") {
      req.log.info({ email: parent.email, requestId: row.id, link, cancelLink }, "[mfa-reset] email hook: confirm + cancel (templates deferred)");
    } else {
      req.log.info({ requestId: row.id }, "[mfa-reset] email hook: confirm + cancel not sent (templates deferred)");
    }
    return {
      ok: true,
      requestId: row.id,
      expiresAt: new Date(Date.now() + MFA_RESET_MAILBOX_TTL_SECONDS * 1000).toISOString(),
      ...(echoResetTokens ? { confirmToken: token } : {}),
    };
  });

  /**
   * The mailbox step: consume the 30-minute single-use link, mark the request `mailbox_confirmed`,
   * and only now tell the family's paired devices to show the code (claim 1b).
   *
   * A family whose only witness is a second parent gets no code and no command; the approving parent
   * is the witness.
   */
  app.post("/mfa/reset/confirm", { config: RL }, async (req, reply) => {
    const parsed = z.object({ token: z.string().min(1) }).safeParse(req.body);
    if (!parsed.success) return reply.code(400).send({ error: parsed.error.flatten() });
    let payload: { sub: string; purpose?: string; jti?: string };
    try {
      payload = app.jwt.verify(parsed.data.token);
    } catch {
      return reply.code(401).send({ error: "invalid_or_expired_token" });
    }
    if (payload.purpose !== "mfa_reset_confirm" || !payload.jti) {
      return reply.code(401).send({ error: "invalid_or_expired_token" });
    }
    // Atomic single use, the same Lua GET+DEL `/reset/confirm` uses (Redis 5.0 has no GETDEL).
    let record: string | null;
    try {
      record = (await getRedis().eval(
        "local v = redis.call('GET', KEYS[1]); if v then redis.call('DEL', KEYS[1]) end; return v",
        1,
        resetConfirmKey(payload.jti),
      )) as string | null;
    } catch (err) {
      req.log.error({ err }, "[security] MFA reset link store unreachable — refusing confirm");
      return reply.code(503).send({ error: "reset_unavailable" });
    }
    if (!record) return reply.code(401).send({ error: "invalid_or_expired_token" });
    const [requestId, parentId] = record.split("|");
    if (!requestId || parentId !== payload.sub) return reply.code(401).send({ error: "invalid_or_expired_token" });
    const request = await prisma.mfaResetRequest.findUnique({ where: { id: requestId } });
    if (!request) return reply.code(401).send({ error: "invalid_or_expired_token" });
    if (request.state !== "requested") return reply.code(409).send({ error: "request_not_open" });

    const [parent, devices] = await Promise.all([
      prisma.parent.findUnique({ where: { id: request.parentId }, select: { displayName: true } }),
      prisma.device.findMany({ where: { child: { familyId: request.familyId } }, select: { id: true } }),
    ]);
    const code = devices.length > 0 ? generateResetCode() : null;
    const confirmedAt = new Date();
    const codeExpiresAt = code ? new Date(confirmedAt.getTime() + MFA_RESET_CODE_TTL_SECONDS * 1000) : null;
    const claimed = await prisma.mfaResetRequest.updateMany({
      where: { id: request.id, state: "requested" },
      data: {
        state: "mailbox_confirmed",
        emailConfirmedAt: confirmedAt,
        ...(code && codeExpiresAt ? { codeHash: hashResetCode(code), codeExpiresAt } : {}),
      },
    });
    if (claimed.count !== 1) return reply.code(409).send({ error: "request_not_open" });

    if (code && codeExpiresAt) {
      try {
        for (const device of devices) {
          await enqueueDeviceCommand(
            device.id,
            "show_reset_code",
            {
              requestId: request.id,
              parentName: parent?.displayName ?? "",
              code,
              expiresAt: codeExpiresAt.toISOString(),
            },
            // The command lives exactly as long as the code it carries.
            { ttlSeconds: MFA_RESET_CODE_TTL_SECONDS },
          );
        }
      } catch (err) {
        // Fail closed and say so: the mailbox step is spent, no phone can show the code, and the
        // 24-hour expiry ends the request. Answering 200 would promise a code nobody received.
        req.log.error({ err, requestId: request.id }, "[mfa-reset] witness dispatch failed");
        return reply.code(503).send({ error: "witness_dispatch_failed", requestId: request.id });
      }
    }
    return {
      ok: true,
      requestId: request.id,
      witness: code ? "device" : "parent",
      ...(codeExpiresAt ? { codeExpiresAt: codeExpiresAt.toISOString() } : {}),
    };
  });

  /**
   * Submit the 8-digit code shown on a paired device. Unauthenticated by construction: the parent
   * being reset cannot hold a session — `/login` needs the authenticator they lost — so the request id
   * (a 122-bit uuid, returned only to whoever passed the password and mailbox steps) and the code are
   * the whole proof. Five wrong codes end the request (claim 1c).
   */
  app.post("/mfa/reset/witness", { config: RL }, async (req, reply) => {
    const parsed = z
      .object({ requestId: z.string().min(1).max(64), code: z.string().regex(/^\d{8}$/) })
      .safeParse(req.body);
    if (!parsed.success) return reply.code(400).send({ error: parsed.error.flatten() });
    const request = await prisma.mfaResetRequest.findUnique({ where: { id: parsed.data.requestId } });
    if (!request) return reply.code(401).send({ error: "invalid_witness" });
    if (request.state !== "mailbox_confirmed") return reply.code(409).send({ error: "request_not_open" });
    // An expired code spends no attempt: a guess against it cannot win, so the counter would only
    // burn the request for a parent who needs a fresh link.
    if (!request.codeHash || !request.codeExpiresAt || request.codeExpiresAt.getTime() <= Date.now()) {
      return reply.code(401).send({ error: "invalid_witness" });
    }
    if (!resetCodeMatches(parsed.data.code, request.codeHash)) {
      // One atomic increment with RETURNING, so two concurrent guesses cannot both read "4".
      const rows = await prisma.$queryRaw<Array<{ failedCodeAttempts: number }>>`
        UPDATE "MfaResetRequest"
        SET "failedCodeAttempts" = "failedCodeAttempts" + 1
        WHERE "id" = ${request.id} AND "state" = 'mailbox_confirmed'
        RETURNING "failedCodeAttempts"`;
      if (!rows[0]) return reply.code(409).send({ error: "request_not_open" });
      const attempts = rows[0].failedCodeAttempts;
      if (attempts >= MFA_RESET_MAX_CODE_ATTEMPTS) {
        await prisma.mfaResetRequest.updateMany({
          where: { id: request.id, state: "mailbox_confirmed" },
          data: { state: "too_many_attempts", outcomeAt: new Date() },
        });
        await clearResetCodePayloads(request.id).catch(() => 0);
        return reply.code(401).send({ error: "too_many_attempts" });
      }
      return reply.code(401).send({ error: "invalid_witness", attemptsRemaining: MFA_RESET_MAX_CODE_ATTEMPTS - attempts });
    }
    const windowEndsAt = await passWitness(request, { kind: "device", ref: null }, req);
    if (!windowEndsAt) return reply.code(409).send({ error: "request_not_open" });
    return { ok: true, state: "witness_passed", windowEndsAt: windowEndsAt.toISOString() };
  });

  /**
   * The other witness: another `owner` or `co-parent` of the same family approves from their own
   * signed-in app (claim 4). A `guardian` cannot — that access is deliberately partial — and a parent
   * of another family cannot, even an owner of one.
   *
   * The scope is the *request's* family, not the token's snapshot, so the check cannot be borrowed.
   */
  app.post("/mfa/reset/approve", { preHandler: requireJwt, config: RL }, async (req, reply) => {
    const parsed = z.object({ requestId: z.string().min(1).max(64) }).safeParse(req.body);
    if (!parsed.success) return reply.code(400).send({ error: parsed.error.flatten() });
    const user = req.user as { sub: string };
    const caller = await prisma.parent.findUnique({ where: { id: user.sub } });
    if (!caller) return reply.code(404).send({ error: "parent_not_found" });
    const request = await prisma.mfaResetRequest.findUnique({ where: { id: parsed.data.requestId } });
    if (!request) return reply.code(404).send({ error: "not_found" });
    if (request.familyId !== caller.familyId) return reply.code(403).send({ error: "forbidden" });
    if (request.parentId === caller.id) return reply.code(403).send({ error: "forbidden" });
    if (caller.role !== "owner" && caller.role !== "co-parent") return reply.code(403).send({ error: "role_not_allowed" });
    if (request.state !== "mailbox_confirmed") return reply.code(409).send({ error: "request_not_open" });

    const windowEndsAt = await passWitness(request, { kind: "parent", ref: caller.id }, req);
    if (!windowEndsAt) return reply.code(409).send({ error: "request_not_open" });
    return { ok: true, state: "witness_passed", windowEndsAt: windowEndsAt.toISOString() };
  });

  /**
   * Cancel a request. Two callers, one outcome, and neither needs anything the other has:
   *
   *  - the cancel link, one click, no sign-in — cancelling can only keep things as they are;
   *  - another owner or co-parent of the family, signed in, from their app.
   *
   * Cancelling is idempotent: a request that has already left the open set answers with its state.
   */
  app.post("/mfa/reset/cancel", { config: RL }, async (req, reply) => {
    const parsed = z
      .object({ token: z.string().min(1).optional(), requestId: z.string().min(1).max(64).optional() })
      .safeParse(req.body ?? {});
    if (!parsed.success) return reply.code(400).send({ error: parsed.error.flatten() });

    const finish = async (requestId: string, state: "cancelled_by_link" | "cancelled_by_parent", reason: "link" | "parent") => {
      const updated = await prisma.mfaResetRequest.updateMany({
        where: { id: requestId, state: { in: [...OPEN_RESET_STATES] } },
        data: { state, cancelledReason: reason, outcomeAt: new Date() },
      });
      if (updated.count === 1) {
        await clearResetCodePayloads(requestId).catch((err) =>
          req.log.warn({ err }, "[mfa-reset] could not clear the device code payload after cancellation"),
        );
      }
      const fresh = await prisma.mfaResetRequest.findUnique({ where: { id: requestId } });
      return reply.send({ ok: true, state: fresh?.state ?? state });
    };

    if (parsed.data.token) {
      let payload: { sub?: string; purpose?: string; requestId?: string };
      try {
        payload = app.jwt.verify(parsed.data.token);
      } catch {
        return reply.code(401).send({ error: "invalid_or_expired_token" });
      }
      if (payload.purpose !== "mfa_reset_cancel" || !payload.requestId || !payload.sub) {
        return reply.code(401).send({ error: "invalid_or_expired_token" });
      }
      const request = await prisma.mfaResetRequest.findUnique({ where: { id: payload.requestId } });
      // The link names one request and one parent; anything else is a stale or forged link.
      if (!request || request.parentId !== payload.sub) {
        return reply.code(401).send({ error: "invalid_or_expired_token" });
      }
      return finish(request.id, "cancelled_by_link", "link");
    }

    try {
      await req.jwtVerify();
    } catch {
      return reply.code(401).send({ error: "unauthorized" });
    }
    const user = req.user as { sub?: string; role?: string; purpose?: string; jti?: string; iat?: number; sv?: number };
    if (!isBearerSession(user) || user.role !== "parent" || !user.sub) {
      return reply.code(401).send({ error: "unauthorized" });
    }
    if (!(await isParentSessionLive(user))) return reply.code(401).send({ error: "session_revoked" });
    if (!parsed.data.requestId) return reply.code(400).send({ error: "request_id_required" });
    const caller = await prisma.parent.findUnique({ where: { id: user.sub } });
    if (!caller) return reply.code(404).send({ error: "parent_not_found" });
    const request = await prisma.mfaResetRequest.findUnique({ where: { id: parsed.data.requestId } });
    if (!request) return reply.code(404).send({ error: "not_found" });
    if (request.familyId !== caller.familyId) return reply.code(403).send({ error: "forbidden" });
    if (request.parentId === caller.id) return reply.code(403).send({ error: "forbidden" });
    if (caller.role !== "owner" && caller.role !== "co-parent") return reply.code(403).send({ error: "role_not_allowed" });
    return finish(request.id, "cancelled_by_parent", "parent");
  });

  /**
   * The end of the wait: `{email, password, requestId}`, refused until `windowEndsAt` (claim 1d) and
   * for any request that is not `witness_passed`.
   *
   * On success it runs ADR-0023's recovery sequence exactly as amended on 2026-10-22 (decision 5):
   * register the recovery token's record, revoke every session, one transaction that clears
   * `mfaSecret`, deletes any remaining codes and records the outcome, then sign the 15-minute
   * `purpose: "mfa_recovery"` token. `mfaEnabled` stays true, so the account still demands a second
   * factor and `/login` answers `mfa_reenroll_required` until the parent enrols again (claim 5).
   *
   * There is no second "MFA cleared" path in this file, and this one refuses everything except a
   * request that passed its witness and waited out its window.
   */
  app.post("/mfa/reset/complete", { config: RL }, async (req, reply) => {
    const parsed = z
      .object({
        email: z.string().email().transform((e) => e.trim().toLowerCase()),
        password: z.string().min(1).max(256),
        requestId: z.string().min(1).max(64),
      })
      .safeParse(req.body);
    if (!parsed.success) return reply.code(400).send({ error: parsed.error.flatten() });
    const parent = await prisma.parent.findUnique({ where: { email: parsed.data.email } });
    const passwordHash = parent?.passwordHash ?? (await unknownParentPasswordHash());
    const passwordOk = await argon2.verify(passwordHash, parsed.data.password).catch(() => false);
    if (!parent || !passwordOk) return reply.code(401).send({ error: "invalid_credentials" });

    const request = await prisma.mfaResetRequest.findUnique({ where: { id: parsed.data.requestId } });
    // "No such request" and "another parent's request" are one answer: this route is not an oracle
    // for other accounts' request ids.
    if (!request || request.parentId !== parent.id) return reply.code(404).send({ error: "request_not_found" });

    const refusals: Record<string, string> = {
      requested: "witness_required",
      mailbox_confirmed: "witness_required",
      cancelled_by_signin: "request_cancelled",
      cancelled_by_link: "request_cancelled",
      cancelled_by_parent: "request_cancelled",
      expired: "request_expired",
      too_many_attempts: "too_many_attempts",
      completed: "request_completed",
    };
    const refusal = refusals[request.state];
    if (refusal) return reply.code(409).send({ error: refusal });
    if (request.state !== "witness_passed") return reply.code(409).send({ error: "request_not_open" });

    // Claim 1d: before the window ends nothing changes at all — no token, no revocation, no write.
    const windowEndsAt = request.windowEndsAt;
    if (!windowEndsAt || windowEndsAt.getTime() > Date.now()) return reply.code(409).send({ error: "window_open" });

    // ADR-0023 step 1: the token's record first, so a failure after the commit cannot leave the
    // parent recovered with no token (#199's lockout, one path across).
    const jti = randomBytes(16).toString("hex");
    await getRedis().set(recoveryKey(jti), parent.id, "EX", RECOVERY_TTL_SECONDS);
    // Step 2: every session, not best-effort (#199): if this throws the request stays open.
    await revokeAllRefreshTokens(parent.id);

    // Step 3: one transaction — the factor goes, the remaining codes go, the outcome is recorded once.
    const completedAt = new Date();
    const consumed = await prisma.$transaction(async (tx) => {
      const claimed = await tx.mfaResetRequest.updateMany({
        where: { id: request.id, state: "witness_passed" },
        data: { state: "completed", completedAt, outcomeAt: completedAt },
      });
      if (claimed.count !== 1) return false;
      await tx.parentMfaRecoveryCode.deleteMany({ where: { parentId: parent.id } });
      // #183: only the factor goes; the policy stays on, exactly as `/mfa/recover` leaves it.
      await tx.parent.update({ where: { id: parent.id }, data: { mfaEnabled: true, mfaSecret: null } });
      return true;
    });
    if (!consumed) {
      await getRedis().del(recoveryKey(jti)).catch(() => {});
      return reply.code(409).send({ error: "request_not_open" });
    }
    await clearResetCodePayloads(request.id).catch(() => 0);

    // Step 4: the same 15-minute purpose-scoped token `/mfa/recover` signs. No new token type.
    const recoveryToken = app.jwt.sign(
      { sub: parent.id, purpose: "mfa_recovery", jti },
      { expiresIn: `${RECOVERY_CODE_TTL_MINUTES}m` },
    );
    // Completion notice hook, templates deferred (ADR-0031 decision 4).
    req.log.info({ requestId: request.id }, "[mfa-reset] completion notice hook: email + push not sent (templates deferred)");
    return { recoveryToken };
  });

  // --- ADR-0031 amendment 2026-10-23: the two reads the parent app needs -------------------------
  // Decision 8's read for "the parent it is about" had no route the requester could use, because that
  // parent has no session; and a co-parent's approval prompt had no way to find a request or name its
  // requester. This is exactly two routes, both read-only. Neither adds a state, a token or a cancel
  // path: the state machine and decision 3's cancel rules are unchanged.

  /** `createdAt` + 30 min, the mailbox link's life (decision 2.2) — only a `requested` row waits on it. */
  const mailboxLinkExpiresAt = (request: { state: string; createdAt: Date }): Date | null =>
    request.state === "requested" ? new Date(request.createdAt.getTime() + MFA_RESET_MAILBOX_TTL_SECONDS * 1000) : null;

  /** `emailConfirmedAt` + 24 h, the witness step's deadline (decision 3) — only `mailbox_confirmed` waits. */
  const witnessDeadline = (request: { state: string; emailConfirmedAt: Date | null }): Date | null =>
    request.state === "mailbox_confirmed" && request.emailConfirmedAt
      ? new Date(request.emailConfirmedAt.getTime() + MFA_RESET_WITNESS_DEADLINE_MS)
      : null;

  /**
   * The read-only view of one request: the stage and the deadline that stage is waiting on, and
   * nothing that is a credential.
   *
   * The fields are listed here, never spread from the row, so `codeHash`, the plaintext code,
   * `witnessRef`, device ids and anything about another parent are absent by construction rather than
   * by filtering. A derived field that does not apply to the current state is `null`, never a stale
   * value: the link exists only while `requested`; the code, its deadline and the attempt count only
   * while `mailbox_confirmed` (the code is spent when the witness passes). `emailConfirmedAt`,
   * `witnessKind`, `witnessAt`, `windowEndsAt` and `outcomeAt` are the row's own nulls when the
   * request never reached them.
   */
  const resetStatusView = (request: MfaResetRequestRow) => ({
    requestId: request.id,
    state: request.state,
    createdAt: request.createdAt,
    emailConfirmedAt: request.emailConfirmedAt,
    mailboxLinkExpiresAt: mailboxLinkExpiresAt(request),
    witnessDeadline: witnessDeadline(request),
    codeExpiresAt: request.state === "mailbox_confirmed" ? request.codeExpiresAt : null,
    attemptsRemaining:
      request.state === "mailbox_confirmed" ? MFA_RESET_MAX_CODE_ATTEMPTS - request.failedCodeAttempts : null,
    witnessKind: request.witnessKind,
    witnessAt: request.witnessAt,
    windowEndsAt: request.windowEndsAt,
    outcomeAt: request.outcomeAt,
  });

  /**
   * The requester re-reads their own request (amendment 2026-10-23, item 1).
   *
   * `POST`, not `GET`, because a password never goes in a URL — and the front door is `/complete`'s,
   * copied from it: this route's own 20/min bucket, the dummy hash for an unknown address so the work
   * is the same either way, `401 invalid_credentials` for a bad email or password, and one
   * `404 request_not_found` for "no such id" and "another parent's id" alike, so it is not an oracle
   * for other accounts' request ids.
   *
   * **It writes nothing.** It is not a sign-in, so it must not cancel the request: decision 3 makes a
   * successful sign-in the cancel signal precisely because that needs the authenticator this parent
   * has lost. It revokes nothing, acks nothing, and touches no row, command, email or counter except
   * this route's own rate-limit bucket.
   */
  app.post("/mfa/reset/status", { config: RL }, async (req, reply) => {
    const parsed = z
      .object({
        email: z.string().email().transform((e) => e.trim().toLowerCase()),
        password: z.string().min(1).max(256),
        requestId: z.string().min(1).max(64),
      })
      .safeParse(req.body);
    if (!parsed.success) return reply.code(400).send({ error: parsed.error.flatten() });
    const parent = await prisma.parent.findUnique({ where: { email: parsed.data.email } });
    // The same unknown-address path as `/complete` and `/login`: verify against a dummy hash so timing
    // does not distinguish the two, and answer one refusal.
    const passwordHash = parent?.passwordHash ?? (await unknownParentPasswordHash());
    const passwordOk = await argon2.verify(passwordHash, parsed.data.password).catch(() => false);
    if (!parent || !passwordOk) return reply.code(401).send({ error: "invalid_credentials" });

    const request = await prisma.mfaResetRequest.findUnique({ where: { id: parsed.data.requestId } });
    if (!request || request.parentId !== parent.id) return reply.code(404).send({ error: "request_not_found" });

    return resetStatusView(request);
  });

  /**
   * The family's open requests, for whoever has to act on one before decision 4's push messages exist
   * (amendment 2026-10-23, item 2): another `owner`/`co-parent` approving (decision 2.3) or cancelling
   * (decision 3) from their own app.
   *
   * The gate is `/approve`'s, copied: a live parent session, then the caller's own row, then the role —
   * a `guardian` is refused `403 role_not_allowed` because partial access is not approval. Only
   * `mailbox_confirmed` and `witness_passed` are listed: nothing reaches a child device before the
   * mailbox step, and an approval comes after it. The caller's own requests are not listed — those are
   * what `status` is for, and this list exists to act on someone else's.
   *
   * The requester's `displayName` and role are returned because the prompt has to name them. The
   * address is not, and neither is `witnessRef`.
   */
  app.get("/mfa/reset/pending", { preHandler: requireJwt, config: RL }, async (req, reply) => {
    const user = req.user as { sub: string };
    const caller = await prisma.parent.findUnique({ where: { id: user.sub } });
    if (!caller) return reply.code(404).send({ error: "parent_not_found" });
    if (caller.role !== "owner" && caller.role !== "co-parent") return reply.code(403).send({ error: "role_not_allowed" });

    // The caller's family, not a token snapshot: the same rule `/approve` applies to the request's
    // family, so the scope cannot be borrowed from a stale claim.
    const open = await prisma.mfaResetRequest.findMany({
      where: {
        familyId: caller.familyId,
        parentId: { not: caller.id },
        state: { in: ["mailbox_confirmed", "witness_passed"] },
      },
      orderBy: { createdAt: "asc" },
      select: { id: true, parentId: true, state: true, createdAt: true, emailConfirmedAt: true, windowEndsAt: true },
    });
    const requesters = open.length
      ? await prisma.parent.findMany({
          where: { id: { in: [...new Set(open.map((request) => request.parentId))] } },
          select: { id: true, displayName: true, role: true },
        })
      : [];
    const byId = new Map(requesters.map((parent) => [parent.id, parent]));
    return {
      requests: open.map((request) => {
        // A request cascades with its parent row, so a missing one is unreachable in practice.
        const requester = byId.get(request.parentId);
        return {
          requestId: request.id,
          state: request.state,
          requester: {
            parentId: request.parentId,
            displayName: requester?.displayName ?? "",
            role: requester?.role ?? "",
          },
          createdAt: request.createdAt,
          emailConfirmedAt: request.emailConfirmedAt,
          witnessDeadline: witnessDeadline(request),
          windowEndsAt: request.windowEndsAt,
        };
      }),
    };
  });

  // --- #167: a password-reset link is single-use ------------------------------------------------
  // `reset:<jti>` is the record the Lua consume removes (the token's `jti` is its only identity);
  // `reset:latest:<parentId>` names the one jti still honoured, so a second /reset/request kills the
  // first. Both live 15 minutes, the token's own lifetime.
  const RESET_TTL_SECONDS = 15 * 60;
  /** One link per address per minute — see the SET NX at the top of /reset/request. */
  const RESET_COOLDOWN_SECONDS = 60;
  const resetKey = (jti: string) => `reset:${jti}`;
  const resetLatestKey = (parentId: string) => `reset:latest:${parentId}`;
  const resetCooldownKey = (email: string) => `reset:cooldown:${createHash("sha256").update(email).digest("hex")}`;

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
    const redis = getRedis();
    // #167 review: one link per address per minute, claimed *before* the parent lookup. Two reasons:
    // the cooldown stops a stranger from repeatedly superseding a parent's newest link (and flooding
    // their inbox) — a lever the supersession rule creates; and because the claim runs first, a Redis
    // outage answers the same 503 for a known and an unknown address alike.
    let claimed: string | null;
    try {
      claimed = await redis.set(resetCooldownKey(parsed.data.email), "1", "EX", RESET_COOLDOWN_SECONDS, "NX");
    } catch (err) {
      req.log.error({ err }, "[security] reset cooldown store unreachable — refusing reset request");
      return reply.code(503).send({ error: "reset_unavailable" });
    }
    // Inside the cooldown: the same `{ok:true}` as a fresh request, but no new link and no email.
    if (claimed === null) return { ok: true };
    // A failure after the claim must release it, or the parent's retry inside the minute is told
    // "sent" while nothing was sent — the rule the cooldown was built on. The release runs only on
    // failure paths, and the lookup that can fail runs for known and unknown addresses alike, so it
    // reveals nothing (and /register's 409 already publishes existence).
    const releaseCooldown = () => redis.del(resetCooldownKey(parsed.data.email)).catch(() => 0);
    try {
      const parent = await prisma.parent.findUnique({ where: { email: parsed.data.email } });
      if (parent) {
        const jti = newJti();
        const token = app.jwt.sign({ sub: parent.id, purpose: "password_reset", jti }, { expiresIn: "15m" });
        // Issuing a link that can never be redeemed is worse than a 5xx, so both writes are awaited
        // before the email goes out. Superseding is the `latest` write alone: the older key stays
        // until its TTL, but no confirm will honour it.
        await redis.set(resetKey(jti), parent.id, "EX", RESET_TTL_SECONDS);
        await redis.set(resetLatestKey(parent.id), jti, "EX", RESET_TTL_SECONDS);
        // Phase 2a: the live token goes only into the email (audit API-07: it used to be logged).
        const link = `${appPublicUrl()}/reset?token=${encodeURIComponent(token)}`;
        const result = await getEmailSender().send(passwordResetEmail(parent.email, link));
        if (!result.ok) {
          req.log.error({ reason: result.reason }, "password reset email failed");
          await releaseCooldown(); // provider refused: let the parent's retry send again
        }
      }
    } catch (err) {
      await releaseCooldown();
      req.log.error({ err }, "[security] reset request failed after the cooldown claim; released for the retry");
      return reply.code(503).send({ error: "reset_unavailable" });
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
    // Atomic single use, before the hash is computed: the Lua GET+DEL returns the owner to exactly
    // one caller, so of two concurrent confirmations of the same link only one can proceed. A missing
    // key is a spent, superseded or expired token. Redis 5.0 has no GETDEL (the shared test server
    // runs 5.0.14, and devices.ts:217 uses this same script for pairing codes).
    let owner: string | null;
    try {
      owner = (await redis.eval(
        "local v = redis.call('GET', KEYS[1]); if v then redis.call('DEL', KEYS[1]) end; return v",
        1,
        resetKey(payload.jti),
      )) as string | null;
    } catch (err) {
      // Not a spent link but an unreachable store: report a 5xx, which the #162 retry contract
      // already treats as transient, instead of telling the parent the link is dead. A script that
      // fails to run deletes nothing, so there is no record to restore.
      req.log.error({ err }, "[security] reset-token store unreachable — refusing reset confirm");
      return reply.code(503).send({ error: "reset_unavailable" });
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
      req.log.error({ err }, "[security] reset-token store unreachable after the consume; restored for the retry");
      return reply.code(503).send({ error: "reset_unavailable" });
    }
    if (latest !== payload.jti) return reply.code(401).send({ error: "invalid_or_expired_token" });

    let passwordHash: string;
    try {
      passwordHash = await argon2.hash(parsed.data.password);
    } catch (err) {
      await restoreResetToken(payload.sub, payload.jti, payload.exp, req);
      req.log.error({ err }, "[security] password hashing failed after the reset token was consumed; restored for the retry");
      return reply.code(503).send({ error: "reset_unavailable" });
    }
    try {
      await prisma.parent.update({ where: { id: payload.sub }, data: { passwordHash } });
    } catch (err) {
      // Review API-8 answered 404 for "parent deleted between issuance and confirmation", which is
      // right for a *missing* parent but was used for every failure, so a transient database error
      // told the client its account was gone and the retry #162 promised never came. Decide from the
      // update error alone: P2025 is "record not found", everything else is transient. A re-read here
      // turned "cannot reach the database" into "not found" (and killed the link), so there is none.
      if (err instanceof Prisma.PrismaClientKnownRequestError && err.code === "P2025") {
        return reply.code(404).send({ error: "account_not_found" }); // really gone: link stays dead
      }
      await restoreResetToken(payload.sub, payload.jti, payload.exp, req);
      req.log.error({ err }, "[security] password update failed after the reset token was consumed; restored for the retry");
      return reply.code(503).send({ error: "reset_unavailable" });
    }
    // Handoff item 3: a password change revokes every existing session. This must not be reported as
    // success when it throws (#162/#135: a revocation that did not happen is a 5xx), and the restored
    // token is what makes the client's retry succeed.
    try {
      await revokeAllRefreshTokens(payload.sub);
    } catch (err) {
      await restoreResetToken(payload.sub, payload.jti, payload.exp, req);
      req.log.error({ err }, "[security] session revocation failed after the reset token was consumed; restored for the retry");
      return reply.code(503).send({ error: "reset_unavailable" });
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
            // ADR-0032: this is a revocation too, so it is written where a restart cannot lose it.
            // The version bump above already kills the token (it was minted at the previous `sv`);
            // the row covers the case the other way round, and costs one upsert on a path that has
            // already touched Postgres through `invalidateSessionsBefore`.
            await revokeTokenOnce(jti, parentId, 24 * 3600);
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
      // ADR-0032: the record goes to Postgres before the cache, so a restarted or evicted Redis
      // cannot bring the token back. Both writes fail closed — a 200 that means "logged out" must
      // not rest on a revocation that exists nowhere durable.
      //
      // `parentId` is read from the same refresh record as `jti`, so it is present whenever `jti` is;
      // the empty-string fallback only covers a record someone wrote without one, and such a row is
      // stored for the record (its parent's cache rebuild cannot find it, and a refresh record with
      // no owner cannot be rotated back into a session anyway).
      if (jti) await revokeTokenOnce(jti, parentId ?? "");
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
