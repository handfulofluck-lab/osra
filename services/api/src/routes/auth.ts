import type { FastifyInstance, FastifyReply, FastifyRequest } from "fastify";
import { createHash, randomBytes, timingSafeEqual } from "node:crypto";
import argon2 from "argon2";
import { z } from "zod";
import { prisma } from "../db.js";
import { generateTotpSecret, totpAtCounter } from "../lib/totp.js";
import { getRedis } from "../redis.js";

// Parent access tokens live 7 days; device tokens are minted separately with a 10y life.
const PARENT_TOKEN_TTL = "7d";

const RegisterSchema = z.object({
  email: z.string().email().transform((e) => e.trim().toLowerCase()),
  password: z.string().min(12),
  displayName: z.string().min(1),
  familyName: z.string().min(1),
  region: z.enum(["US", "EU", "UK", "OTHER"]),
});

const LoginSchema = z.object({
  email: z.string().email().transform((e) => e.trim().toLowerCase()),
  password: z.string(),
});

/**
 * Verify a login TOTP code with replay protection (review 3.1): the accepted
 * time-step counter is stored per parent, so a captured code cannot be reused
 * within its validity window.
 */
async function verifyTotpFresh(parentId: string, secret: string | null, code: string): Promise<boolean> {
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
  // Live key  refresh:{sha256(token)}            -> JSON {parentId, expiresAt} (30 d TTL)
  // Marker    refresh:used:{sha256(token)}       -> "1" (rotation/reuse detection, same TTL)
  // Index     refresh:index:{parentId}           -> SET of live token hashes (for logout-all)
  const hashToken = (token: string) => createHash("sha256").update(token).digest("hex");
  const liveKey = (hash: string) => `refresh:${hash}`;
  const usedKey = (hash: string) => `refresh:used:${hash}`;
  const indexKey = (parentId: string) => `refresh:index:${parentId}`;

  /** Issue a new opaque refresh token, storing only its sha256 hash in Redis. */
  const issueRefreshToken = async (parentId: string): Promise<string> => {
    const token = randomBytes(48).toString("hex");
    const hash = hashToken(token);
    const redis = getRedis();
    await redis.set(liveKey(hash), JSON.stringify({ parentId, expiresAt: Date.now() + REFRESH_TTL_MS }), "EX", Math.floor(REFRESH_TTL_MS / 1000));
    await redis.sadd(indexKey(parentId), hash);
    return token;
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
  };

  app.post("/register", { config: RL }, async (req, reply) => {
    const parsed = RegisterSchema.safeParse(req.body);
    if (!parsed.success) return reply.code(400).send({ error: parsed.error.flatten() });
    const { email: rawEmail, password, displayName, familyName, region } = parsed.data;
    const email = rawEmail.trim().toLowerCase();

    const existing = await prisma.parent.findUnique({ where: { email } });
    if (existing) return reply.code(409).send({ error: "email_taken" });

    const passwordHash = await argon2.hash(password);
    const result = await prisma.$transaction(async (tx) => {
      const family = await tx.family.create({ data: { name: familyName, region } });
      const parent = await tx.parent.create({
        data: { familyId: family.id, email, passwordHash, displayName, role: "owner" },
      });
      return { family, parent };
    });

    const token = app.jwt.sign({ sub: result.parent.id, familyId: result.family.id, role: "parent" }, { expiresIn: PARENT_TOKEN_TTL });
    return reply.code(201).send({ token, refreshToken: await issueRefreshToken(result.parent.id), parent: { id: result.parent.id, email, displayName } });
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
    const token = app.jwt.sign({ sub: parent.id, familyId: parent.familyId, role: "parent" }, { expiresIn: PARENT_TOKEN_TTL });
    return { token, refreshToken: await issueRefreshToken(parent.id) };
  });

  /** Require a valid parent JWT for the MFA endpoints. */
  const requireJwt = async (req: FastifyRequest, reply: FastifyReply) => {
    try {
      await req.jwtVerify();
    } catch {
      await reply.code(401).send({ error: "unauthorized" });
    }
  };

  /** Generate a TOTP secret for the authenticated parent and return an otpauth URL. */
  app.post("/mfa/enroll", { preHandler: requireJwt, config: RL }, async (req) => {
    const user = req.user as { sub: string };
    const secret = generateTotpSecret();
    const parent = await prisma.parent.update({
      where: { id: user.sub },
      data: { mfaSecret: secret },
    });
    const otpauthUrl = `otpauth://totp/OSRA:${encodeURIComponent(parent.email)}?secret=${secret}&issuer=OSRA`;
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
      console.log(`[email:stub] password reset for ${parent.email}: ${token}`);
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
    const stored = JSON.parse(raw) as { parentId: string; expiresAt: number };
    if (stored.expiresAt < Date.now()) {
      await redis.del(liveKey(hash));
      return reply.code(401).send({ error: "invalid_refresh_token" });
    }
    // Rotation: mark the presented token consumed before issuing new credentials.
    await redis.del(liveKey(hash));
    await redis.set(usedKey(hash), "1", "EX", Math.floor(REFRESH_TTL_MS / 1000));
    await redis.set(`refresh:owner:${hash}`, stored.parentId, "EX", Math.floor(REFRESH_TTL_MS / 1000));
    await redis.srem(indexKey(stored.parentId), hash);
    const parent = await prisma.parent.findUnique({ where: { id: stored.parentId } });
    if (!parent) return reply.code(401).send({ error: "invalid_refresh_token" });
    const jti = randomBytes(16).toString("hex");
    const token = app.jwt.sign({ sub: parent.id, familyId: parent.familyId, role: "parent", jti }, { expiresIn: PARENT_TOKEN_TTL });
    await redis.set(`refresh:jwt:${hash}`, jti, "EX", Math.floor(REFRESH_TTL_MS / 1000));
    return { token, refreshToken: await issueRefreshToken(parent.id) };
  });

  /** Revoke a single refresh token (logout; always 200 — handoff item 2). */
  app.post("/logout", { config: RL }, async (req) => {
    const parsed = z.object({ refreshToken: z.string().min(1) }).safeParse(req.body);
    if (parsed.success) {
      const hash = hashToken(parsed.data.refreshToken);
      const redis = getRedis();
      await redis.del(liveKey(hash));
      await redis.set(usedKey(hash), "1", "EX", Math.floor(REFRESH_TTL_MS / 1000));
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
