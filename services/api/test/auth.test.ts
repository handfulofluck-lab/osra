import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { createHash } from "node:crypto";
import type { FastifyInstance } from "fastify";
import argon2 from "argon2";
import { Prisma } from "@prisma/client";
import { authRoutes } from "../src/routes/auth.js";
import { meRoutes } from "../src/routes/me.js";
import { decryptSecret, encryptSecret } from "../src/lib/secretVault.js";
import { totpAtCounter } from "../src/lib/totp.js";
import { setEmailSender, type EmailMessage, type EmailSender } from "../src/lib/email/index.js";
import { notifyParentsOfAlert, setPushProviders } from "../src/lib/push/notify.js";
import type { PushMessage, PushProvider, PushResult } from "../src/lib/push/types.js";
import { getRedis } from "../src/redis.js";
import { MockRedis, SIGNUP_CONSENTS, authHeader, buildApp, evalSessionVersionScript, prismaMock, resetPrismaMock } from "./helpers.js";

vi.mock("../src/db.js", async () => {
  const { prismaMock } = await import("./helpers.js");
  return { prisma: prismaMock };
});
vi.mock("ioredis", async () => {
  const { MockRedis } = await import("./helpers.js");
  return { Redis: MockRedis };
});

const PASSWORD = "CorrectHorseBatteryStaple!";
const registerBody = {
  email: "demo@osratech.com",
  password: PASSWORD,
  displayName: "Demo Parent",
  familyName: "Demo Family",
  region: "US",
  // ADR-0043 D3: required — an account may not exist without its acceptance row.
  consents: SIGNUP_CONSENTS,
};

class CaptureSender implements EmailSender {
  readonly name = "capture";
  sent: EmailMessage[] = [];
  /** #167 review: make the next send refuse, so the cooldown-release path can be exercised. */
  failNext = false;
  async send(message: EmailMessage) {
    if (this.failNext) {
      this.failNext = false;
      return { ok: false as const, reason: "provider_unavailable" };
    }
    this.sent.push(message);
    return { ok: true as const };
  }
}
const capture = new CaptureSender();

/** Back the mocked Redis with a Map (and its TTLs) so #167's record lifecycle behaves like a store. */
function wireRedisStore() {
  const redis = getRedis() as unknown as MockRedis;
  const store = new Map<string, string>();
  const ttls = new Map<string, number>();
  const expiresAt = new Map<string, number>();
  const sets = new Map<string, Set<string>>();
  /** A key that has outlived its EX is absent, so a mocked clock can expire the cooldown. */
  const live = (k: string): string | null => {
    const deadline = expiresAt.get(k);
    if (deadline !== undefined && deadline <= Date.now()) {
      store.delete(k);
      ttls.delete(k);
      expiresAt.delete(k);
    }
    return store.get(k) ?? null;
  };
  redis.get.mockImplementation(async (k: string) => live(k));
  redis.set.mockImplementation(async (k: string, v: string, ...args: unknown[]) => {
    const ex = args.indexOf("EX");
    const seconds = ex !== -1 && typeof args[ex + 1] === "number" ? (args[ex + 1] as number) : undefined;
    if (args.includes("NX") && live(k) !== null) return null;
    store.set(k, String(v));
    ttls.delete(k);
    expiresAt.delete(k);
    if (seconds !== undefined) {
      ttls.set(k, seconds);
      expiresAt.set(k, Date.now() + seconds * 1000);
    }
    return "OK";
  });
  // Atomic consume, mirroring the production Lua GET+DEL script (Redis 5.0 has no GETDEL), plus the
  // session-version floor/cleanup scripts from `lib/sessions.ts`.
  redis.eval.mockImplementation(async (script: string, _n: number, key: string, floorArg?: string, allowCreateArg?: string) => {
    const sv = evalSessionVersionScript(redis, script, key, floorArg, allowCreateArg);
    if (sv !== undefined) return sv;
    const v = live(key);
    if (v !== null) {
      store.delete(key);
      ttls.delete(key);
      expiresAt.delete(key);
    }
    return v;
  });
  redis.del.mockImplementation(async (...ks: string[]) => ks.reduce((n, k) => n + (store.delete(k) ? 1 : 0), 0));
  redis.incrby.mockImplementation(async (k: string, n: number) => {
    const next = Number(store.get(k) ?? 0) + n;
    store.set(k, String(next));
    return next;
  });
  redis.sadd.mockImplementation(async (k: string, ...members: string[]) => {
    const set = sets.get(k) ?? new Set<string>();
    for (const m of members) set.add(m);
    sets.set(k, set);
    return set.size;
  });
  redis.srem.mockImplementation(async (k: string, ...members: string[]) => {
    const set = sets.get(k);
    if (!set) return 0;
    for (const m of members) set.delete(m);
    return set.size;
  });
  redis.smembers.mockImplementation(async (k: string) => [...(sets.get(k) ?? [])]);
  return { store, ttls, sets };
}

/**
 * Ask for a reset link the way a parent does and return the token from the email. Minting through
 * the route is what puts the #167 record in Redis; a hand-signed JWT has no record and must be
 * refused, which the tests below rely on.
 */
async function requestResetToken(app: FastifyInstance): Promise<string> {
  capture.sent = [];
  const res = await app.inject({
    method: "POST",
    url: "/v1/auth/reset/request",
    payload: { email: registerBody.email },
  });
  expect(res.statusCode).toBe(200);
  const message = capture.sent.at(-1);
  expect(message).toBeTruthy();
  const match = message!.text.match(/reset\?token=([^\s"'<]+)/);
  expect(match).toBeTruthy();
  return decodeURIComponent(match![1]);
}

const confirmReset = (app: FastifyInstance, token: string, password = "NewCorrectHorse12!") =>
  app.inject({ method: "POST", url: "/v1/auth/reset/confirm", payload: { token, password } });

/**
 * The `Parent` column writes a route performs, selected by the field it sets, and the count of the
 * sessions-version bumps among them.
 *
 * By field, not by count: since ADR-0032 `invalidateSessionsBefore` increments
 * `Parent.sessionVersion` through the same `prisma.parent.update`, so "how many times was a parent
 * updated" stopped being one fact — `/reset/confirm` writes the password *and* the counter, and
 * `/mfa/enroll` writes the secret *and* the counter. The assertions below are about the first write,
 * so they select it and count it; a bare `toHaveBeenCalledTimes(1)` would be counting two different
 * facts and could pass or fail for the wrong reason.
 */
const parentWritesOf = (field: "passwordHash" | "mfaSecret") =>
  prismaMock.parent.update.mock.calls
    .map((call) => call[0] as { data?: Record<string, unknown> })
    .filter((arg) => arg?.data !== undefined && arg.data[field] !== undefined);

const sessionVersionWrites = () =>
  prismaMock.parent.update.mock.calls
    .map((call) => call[0] as { data?: Record<string, unknown> })
    .filter((arg) => arg?.data !== undefined && arg.data.sessionVersion !== undefined).length;

describe("auth routes", () => {
  beforeEach(() => {
    resetPrismaMock();
    capture.sent = [];
    capture.failNext = false;
    setEmailSender(capture);
    // The Redis instance is a module singleton in this file: give every test the empty-store
    // defaults so an implementation from one test cannot leak into the next.
    const redis = getRedis() as unknown as MockRedis;
    redis.get.mockImplementation(async () => null);
    redis.eval.mockImplementation(async (...args: unknown[]) => evalSessionVersionScript(redis, args[0], args[2], args[3], args[4]) ?? null);
    redis.set.mockImplementation(async () => "OK");
    redis.del.mockImplementation(async () => 0);
    redis.incrby.mockImplementation(async () => 1);
    redis.sadd.mockImplementation(async () => 1);
    redis.srem.mockImplementation(async () => 1);
    redis.smembers.mockImplementation(async () => []);
    redis.expire.mockImplementation(async () => 1);
  });

  afterEach(() => {
    setEmailSender(null);
  });

  it("registers a new parent (201) and returns a token", async () => {
    const app = await buildApp(authRoutes, "/v1/auth");
    prismaMock.parent.findUnique.mockResolvedValue(null);
    prismaMock.family.create.mockResolvedValue({ id: "fam-1" });
    prismaMock.parent.create.mockResolvedValue({ id: "parent-1", email: registerBody.email });

    const res = await app.inject({ method: "POST", url: "/v1/auth/register", payload: registerBody });
    expect(res.statusCode).toBe(201);
    expect(res.json().token).toBeTruthy();
    expect(res.json().refreshToken).toBeTruthy();
    await app.close();
  });

  it("rejects duplicate registration with 409", async () => {
    const app = await buildApp(authRoutes, "/v1/auth");
    prismaMock.parent.findUnique.mockResolvedValue({ id: "parent-1" });

    const res = await app.inject({ method: "POST", url: "/v1/auth/register", payload: registerBody });
    expect(res.statusCode).toBe(409);
    expect(res.json().error).toBe("email_taken");
    await app.close();
  });

  it("bounds the family name and the parent name at 80 characters (roadmap 2.7)", async () => {
    const app = await buildApp(authRoutes, "/v1/auth");
    prismaMock.parent.findUnique.mockResolvedValue(null);
    prismaMock.family.create.mockResolvedValue({ id: "fam-1" });
    prismaMock.parent.create.mockResolvedValue({ id: "parent-1", email: registerBody.email });

    const tooLong = await app.inject({
      method: "POST",
      url: "/v1/auth/register",
      payload: { ...registerBody, familyName: "F".repeat(81) },
    });
    // Mutant: remove `.max(80)` from `familyName` in RegisterSchema -> 201 and the 81 characters are
    // stored, in the digest subject of every later send.
    expect(tooLong.statusCode).toBe(400);
    expect(prismaMock.family.create).not.toHaveBeenCalled();

    const nameTooLong = await app.inject({
      method: "POST",
      url: "/v1/auth/register",
      payload: { ...registerBody, displayName: "P".repeat(81) },
    });
    expect(nameTooLong.statusCode).toBe(400);

    const atLimit = await app.inject({
      method: "POST",
      url: "/v1/auth/register",
      payload: { ...registerBody, familyName: "F".repeat(80) },
    });
    expect(atLimit.statusCode).toBe(201);
    expect(prismaMock.family.create).toHaveBeenCalledWith(
      expect.objectContaining({ data: expect.objectContaining({ name: "F".repeat(80) }) }),
    );
    await app.close();
  });

  it("logs in with correct password and rejects a bad one with 401", async () => {
    const app = await buildApp(authRoutes, "/v1/auth");
    const passwordHash = await argon2.hash(PASSWORD);
    prismaMock.parent.findUnique.mockResolvedValue({ id: "parent-1", familyId: "fam-1", passwordHash });

    const ok = await app.inject({
      method: "POST",
      url: "/v1/auth/login",
      payload: { email: registerBody.email, password: PASSWORD },
    });
    expect(ok.statusCode).toBe(200);
    expect(ok.json().token).toBeTruthy();

    const bad = await app.inject({
      method: "POST",
      url: "/v1/auth/login",
      payload: { email: registerBody.email, password: "WrongHorseBattery!" },
    });
    expect(bad.statusCode).toBe(401);
    expect(bad.json().error).toBe("invalid_credentials");
    await app.close();
  });

  it("enrolls and verifies MFA TOTP", async () => {
    const app = await buildApp(authRoutes, "/v1/auth");
    let storedSecret = "";
    prismaMock.parent.update.mockImplementation(({ data }: { data: Record<string, unknown> }) => {
      if (typeof data.mfaSecret === "string") storedSecret = data.mfaSecret;
      return Promise.resolve({ id: "parent-1", email: registerBody.email });
    });
    prismaMock.parent.findUnique.mockImplementation(() =>
      Promise.resolve({ id: "parent-1", mfaSecret: storedSecret }),
    );

    const enroll = await app.inject({
      method: "POST",
      url: "/v1/auth/mfa/enroll",
      headers: authHeader(app),
      payload: {},
    });
    expect(enroll.statusCode).toBe(200);
    const { secret, otpauthUrl } = enroll.json();
    expect(secret).toMatch(/^[A-Z2-7]{32}$/);
    expect(otpauthUrl).toContain(`secret=${secret}`);
    // ADR-0014: the row holds the ENCRYPTED secret, never the plaintext the authenticator app gets.
    expect(storedSecret).not.toBe(secret);
    expect(storedSecret.startsWith("enc1:")).toBe(true);
    expect(decryptSecret(storedSecret)).toBe(secret);

    // Wrong code is rejected.
    const wrong = await app.inject({
      method: "POST",
      url: "/v1/auth/mfa/verify",
      headers: authHeader(app),
      payload: { code: "000000" },
    });
    expect(wrong.statusCode).toBe(401);

    // Correct current-window code enables MFA.
    const counter = Math.floor(Date.now() / 1000 / 30);
    const code = totpAtCounter(secret, counter);
    const verify = await app.inject({
      method: "POST",
      url: "/v1/auth/mfa/verify",
      headers: authHeader(app),
      payload: { code },
    });
    expect(verify.statusCode).toBe(200);
    expect(verify.json()).toMatchObject({ ok: true, mfaEnabled: true });
    await app.close();
  });

  it("replacing an existing MFA secret requires re-authentication (password or current TOTP)", async () => {
    const app = await buildApp(authRoutes, "/v1/auth");
    const passwordHash = await argon2.hash(PASSWORD);
    const oldSecret = "JBSWY3DPEHPK3PXP";
    prismaMock.parent.findUnique.mockResolvedValue({
      id: "parent-1",
      email: registerBody.email,
      passwordHash,
      mfaSecret: oldSecret,
      mfaEnabled: true,
    });
    prismaMock.parent.update.mockResolvedValue({ id: "parent-1", email: registerBody.email });

    const h = authHeader(app);
    // A bare session token can no longer rebind the second factor.
    const noReauth = await app.inject({ method: "POST", url: "/v1/auth/mfa/enroll", headers: h, payload: {} });
    expect(noReauth.statusCode).toBe(401);
    expect(noReauth.json().error).toBe("reauth_required");
    const wrongPassword = await app.inject({
      method: "POST",
      url: "/v1/auth/mfa/enroll",
      headers: h,
      payload: { password: "WrongHorseBatteryStaple!" },
    });
    expect(wrongPassword.statusCode).toBe(401);
    expect(wrongPassword.json().error).toBe("reauth_required");
    const wrongCode = await app.inject({ method: "POST", url: "/v1/auth/mfa/enroll", headers: h, payload: { code: "000000" } });
    expect(wrongCode.statusCode).toBe(401);
    expect(prismaMock.parent.update).not.toHaveBeenCalled();

    // The account password is enough to rotate the secret.
    const byPassword = await app.inject({
      method: "POST",
      url: "/v1/auth/mfa/enroll",
      headers: h,
      payload: { password: PASSWORD },
    });
    expect(byPassword.statusCode).toBe(200);
    expect(byPassword.json().secret).toMatch(/^[A-Z2-7]{32}$/);
    expect(byPassword.json().secret).not.toBe(oldSecret);
    expect(prismaMock.parent.update).toHaveBeenCalledWith({
      where: { id: "parent-1" },
      data: { mfaSecret: expect.stringMatching(/^enc1:/) },
    });

    // A current TOTP code from the existing authenticator is the alternative.
    prismaMock.parent.update.mockClear();
    const counter = Math.floor(Date.now() / 1000 / 30);
    const byCode = await app.inject({
      method: "POST",
      url: "/v1/auth/mfa/enroll",
      headers: h,
      payload: { code: totpAtCounter(oldSecret, counter) },
    });
    expect(byCode.statusCode).toBe(200);
    expect(parentWritesOf("mfaSecret")).toHaveLength(1);
    await app.close();
  });

  it("requires a JWT for MFA endpoints (401 without one)", async () => {
    const app = await buildApp(authRoutes, "/v1/auth");
    const res = await app.inject({ method: "POST", url: "/v1/auth/mfa/enroll", payload: {} });
    expect(res.statusCode).toBe(401);
    const verify = await app.inject({
      method: "POST",
      url: "/v1/auth/mfa/verify",
      payload: { code: "123456" },
    });
    expect(verify.statusCode).toBe(401);
    await app.close();
  });

  it("rejects registration with an invalid body (400)", async () => {
    const app = await buildApp(authRoutes, "/v1/auth");
    const shortPassword = await app.inject({
      method: "POST",
      url: "/v1/auth/register",
      payload: { ...registerBody, password: "short" },
    });
    expect(shortPassword.statusCode).toBe(400);

    const badRegion = await app.inject({
      method: "POST",
      url: "/v1/auth/register",
      payload: { ...registerBody, region: "ANTARCTICA" },
    });
    expect(badRegion.statusCode).toBe(400);

    const badEmail = await app.inject({
      method: "POST",
      url: "/v1/auth/register",
      payload: { ...registerBody, email: "not-an-email" },
    });
    expect(badEmail.statusCode).toBe(400);
    expect(prismaMock.family.create).not.toHaveBeenCalled();
    await app.close();
  });

  it("rejects login with a malformed body (400) and an unknown email (401)", async () => {
    const app = await buildApp(authRoutes, "/v1/auth");
    const malformed = await app.inject({
      method: "POST",
      url: "/v1/auth/login",
      payload: { email: "not-an-email" },
    });
    expect(malformed.statusCode).toBe(400);

    prismaMock.parent.findUnique.mockResolvedValue(null);
    const unknown = await app.inject({
      method: "POST",
      url: "/v1/auth/login",
      payload: { email: registerBody.email, password: PASSWORD },
    });
    expect(unknown.statusCode).toBe(401);
    expect(unknown.json().error).toBe("invalid_credentials");
    await app.close();
  });

  it("rejects a malformed MFA code (400) and verify before enrollment (400)", async () => {
    const app = await buildApp(authRoutes, "/v1/auth");
    prismaMock.parent.findUnique.mockResolvedValue({ id: "parent-1", mfaSecret: null });

    const malformed = await app.inject({
      method: "POST",
      url: "/v1/auth/mfa/verify",
      headers: authHeader(app),
      payload: { code: "12345" },
    });
    expect(malformed.statusCode).toBe(400);

    const notEnrolled = await app.inject({
      method: "POST",
      url: "/v1/auth/mfa/verify",
      headers: authHeader(app),
      payload: { code: "123456" },
    });
    expect(notEnrolled.statusCode).toBe(400);
    expect(notEnrolled.json().error).toBe("mfa_not_enrolled");
    await app.close();
  });

  it("rejects an expired TOTP code outside the ±1 step window (401)", async () => {
    const app = await buildApp(authRoutes, "/v1/auth");
    const secret = "JBSWY3DPEHPK3PXP";
    prismaMock.parent.findUnique.mockResolvedValue({ id: "parent-1", mfaSecret: secret });

    // A code from several steps ago must not verify; skip astronomically unlikely
    // collisions with the current ±1 window.
    const counter = Math.floor(Date.now() / 1000 / 30);
    const validNow = new Set([counter - 1, counter, counter + 1].map((c) => totpAtCounter(secret, c)));
    let staleCounter = counter - 10;
    while (validNow.has(totpAtCounter(secret, staleCounter))) staleCounter -= 1;
    const staleCode = totpAtCounter(secret, staleCounter);

    const res = await app.inject({
      method: "POST",
      url: "/v1/auth/mfa/verify",
      headers: authHeader(app),
      payload: { code: staleCode },
    });
    expect(res.statusCode).toBe(401);
    expect(res.json().error).toBe("invalid_code");
    expect(prismaMock.parent.update).not.toHaveBeenCalled();
    await app.close();
  });

  it("reset/request never reveals whether the email exists", async () => {
    const app = await buildApp(authRoutes, "/v1/auth");
    const bad = await app.inject({
      method: "POST",
      url: "/v1/auth/reset/request",
      payload: { email: "not-an-email" },
    });
    expect(bad.statusCode).toBe(400);

    prismaMock.parent.findUnique.mockResolvedValue(null);
    const unknown = await app.inject({
      method: "POST",
      url: "/v1/auth/reset/request",
      payload: { email: "ghost@osratech.com" },
    });
    expect(unknown.statusCode).toBe(200);
    expect(unknown.json().ok).toBe(true);

    prismaMock.parent.findUnique.mockResolvedValue({ id: "parent-1", email: registerBody.email });
    const known = await app.inject({
      method: "POST",
      url: "/v1/auth/reset/request",
      payload: { email: registerBody.email },
    });
    expect(known.statusCode).toBe(200);
    expect(known.json().ok).toBe(true);
    await app.close();
  });

  it("reset/confirm validates the body (400) and rejects garbage tokens (401)", async () => {
    const app = await buildApp(authRoutes, "/v1/auth");
    const shortPassword = await app.inject({
      method: "POST",
      url: "/v1/auth/reset/confirm",
      payload: { token: "anything", password: "short" },
    });
    expect(shortPassword.statusCode).toBe(400);

    const garbage = await app.inject({
      method: "POST",
      url: "/v1/auth/reset/confirm",
      payload: { token: "not-a-jwt", password: "NewCorrectHorse12!" },
    });
    expect(garbage.statusCode).toBe(401);
    expect(garbage.json().error).toBe("invalid_or_expired_token");
    expect(prismaMock.parent.update).not.toHaveBeenCalled();
    await app.close();
  });

  it("reset/confirm is purpose-scoped: a login JWT cannot reset the password", async () => {
    const app = await buildApp(authRoutes, "/v1/auth");
    // A normal login token (role parent, no purpose claim) must not work here.
    const loginToken = app.jwt.sign({ sub: "parent-1", familyId: "fam-1", role: "parent" });
    const bad = await app.inject({
      method: "POST",
      url: "/v1/auth/reset/confirm",
      payload: { token: loginToken, password: "NewCorrectHorse12!" },
    });
    expect(bad.statusCode).toBe(401);
    expect(prismaMock.parent.update).not.toHaveBeenCalled();

    // A purpose-scoped reset token sets the new password (argon2-hashed). #167: it must be one the
    // request issued, because confirmation now consumes the store record its `jti` names.
    wireRedisStore();
    prismaMock.parent.update.mockResolvedValue({ id: "parent-1" });
    const resetToken = await requestResetToken(app);
    const ok = await confirmReset(app, resetToken);
    expect(ok.statusCode).toBe(200);
    const updateArg = prismaMock.parent.update.mock.calls[0][0] as { data: { passwordHash: string } };
    expect(updateArg.data.passwordHash).not.toContain("NewCorrectHorse12!");
    expect(await argon2.verify(updateArg.data.passwordHash, "NewCorrectHorse12!")).toBe(true);
    await app.close();
  });

  // #146: the reset link is not a bearer credential. The exact chain from the issue: an attacker
  // with the mailbox resets the password, mints a second reset token (live after the epoch moved),
  // and used it on /mfa/enroll with the password it just set — then replaced the second factor.
  it("#146: a password-reset token cannot re-key MFA after reset/confirm", async () => {
    const app = await buildApp(authRoutes, "/v1/auth");
    wireRedisStore();
    const NEW_PASSWORD = "NewCorrectHorseBattery!";
    const oldSecret = "JBSWY3DPEHPK3PXP";
    const attackerSecret = "KRSXG5CTMVRXEZLU";
    let parent: Record<string, any> = {
      id: "parent-1",
      familyId: "fam-1",
      email: registerBody.email,
      role: "owner",
      passwordHash: await argon2.hash(PASSWORD),
      mfaSecret: encryptSecret(oldSecret),
      mfaEnabled: true,
    };
    prismaMock.parent.findUnique.mockImplementation(async () => ({ ...parent }));
    prismaMock.parent.update.mockImplementation(async ({ data }: { data: Record<string, any> }) => {
      parent = { ...parent, ...data };
      return { ...parent };
    });

    const login = (password: string, code: string) =>
      app.inject({ method: "POST", url: "/v1/auth/login", payload: { email: registerBody.email, password, code } });
    const counter = Math.floor(Date.now() / 1000 / 30);
    // The account's own authenticator works before the attack.
    expect((await login(PASSWORD, totpAtCounter(oldSecret, counter))).statusCode).toBe(200);

    // Attacker has email only: a real reset link (minted through the route, so #167's record exists)
    // confirms, and the password changes.
    const firstReset = await requestResetToken(app);
    const confirm = await confirmReset(app, firstReset, NEW_PASSWORD);
    expect(confirm.statusCode).toBe(200);
    const updatesAfterReset = prismaMock.parent.update.mock.calls.length;

    // A second reset token, minted after reset/confirm moved the session epoch, is signature-valid
    // and session-live — the shape the bypass relied on.
    const liveResetToken = app.jwt.sign({ sub: parent.id, purpose: "password_reset" }, { expiresIn: "15m" });
    const bearer = { authorization: `Bearer ${liveResetToken}` };

    // No password: previously 401 reauth_required (the token itself still reached the handler).
    const noPassword = await app.inject({ method: "POST", url: "/v1/auth/mfa/enroll", headers: bearer, payload: {} });
    expect(noPassword.statusCode).toBe(401);

    // With the password the reset just set: previously 200 and a replacement secret. This is the
    // takeover step, and it must now stop at the bearer check, before any re-authentication.
    const withPassword = await app.inject({
      method: "POST",
      url: "/v1/auth/mfa/enroll",
      headers: bearer,
      payload: { password: NEW_PASSWORD },
    });
    expect(withPassword.statusCode).toBe(401);
    expect(prismaMock.parent.update).toHaveBeenCalledTimes(updatesAfterReset);

    // The original authenticator still gets in; the attacker's does not. (A later counter: the
    // store-backed Redis now actually records the first login's step, and replay is refused.)
    expect((await login(NEW_PASSWORD, totpAtCounter(oldSecret, counter + 1))).statusCode).toBe(200);
    expect((await login(NEW_PASSWORD, totpAtCounter(attackerSecret, counter + 1))).statusCode).toBe(401);
    await app.close();
  });

  it("#146: a purpose-scoped token is not a bearer credential on the other requireJwt routes", async () => {
    const app = await buildApp(authRoutes, "/v1/auth");
    const { getRedis } = await import("../src/redis.js");
    const { MockRedis: MR } = await import("./helpers.js");
    const redis = getRedis() as unknown as InstanceType<typeof MR>;
    const store = new Map<string, string>();
    redis.smembers.mockImplementation(async () => [...store.keys()]);
    redis.get.mockImplementation(async (k: string) => store.get(k) ?? null);
    redis.set.mockImplementation(async (k: string, v: string) => { store.set(k, String(v)); return "OK"; });
    redis.del.mockImplementation(async (...ks: string[]) => ks.reduce((n, k) => n + (store.delete(k) ? 1 : 0), 0));
    redis.incrby.mockImplementation(async (k: string, n: number) => {
      const next = Number(store.get(k) ?? 0) + n;
      store.set(k, String(next));
      return next;
    });

    // /logout-all is guarded by requireJwt. A reset-purpose token used to revoke the account's
    // sessions; a token with an unknown role used to pass the same check.
    const resetToken = app.jwt.sign({ sub: "parent-1", purpose: "password_reset" }, { expiresIn: "15m" });
    const withRole = app.jwt.sign({ sub: "parent-1", familyId: "fam-1", role: "parent", purpose: "password_reset" });
    const unknownRole = app.jwt.sign({ sub: "parent-1", familyId: "fam-1", role: "service" });

    for (const token of [resetToken, withRole, unknownRole]) {
      const res = await app.inject({
        method: "POST",
        url: "/v1/auth/logout-all",
        headers: { authorization: `Bearer ${token}` },
      });
      expect(res.statusCode).toBe(401);
      expect(res.json().error).toBe("unauthorized");
    }
    expect(store.size).toBe(0);

    // An explicitly session-purpose token and a plain session token still work. Each is signed with
    // the sessions version current at that moment: the first logout-all revokes it, so a token
    // signed before the bump would rightly be dead (#117).
    const sessionVersion = () => Number(store.get("auth:session-version:parent-1") ?? 0);
    for (const claims of [
      { sub: "parent-1", familyId: "fam-1", role: "parent", purpose: "session" },
      { sub: "parent-1", familyId: "fam-1", role: "parent" },
    ]) {
      const token = app.jwt.sign({ ...claims, sv: sessionVersion() });
      const res = await app.inject({
        method: "POST",
        url: "/v1/auth/logout-all",
        headers: { authorization: `Bearer ${token}` },
      });
      expect(res.statusCode).toBe(200);
    }
    await app.close();
  });

  // #167: the link is single-use. The attack was a parent who used it, then someone who saw the
  // mail replaying it inside the 15-minute window to set a password of their own.
  it("#167: a reset token sets the password once; the replay is 401", async () => {
    const app = await buildApp(authRoutes, "/v1/auth");
    wireRedisStore();
    prismaMock.parent.update.mockResolvedValue({ id: "parent-1" });

    const token = await requestResetToken(app);
    const first = await confirmReset(app, token);
    expect(first.statusCode).toBe(200);
    expect(parentWritesOf("passwordHash")).toHaveLength(1);

    const replay = await confirmReset(app, token);
    expect(replay.statusCode).toBe(401);
    expect(replay.json().error).toBe("invalid_or_expired_token");
    // Consumed before the hash/DB work: the replay changed nothing.
    expect(parentWritesOf("passwordHash")).toHaveLength(1);
    await app.close();
  });

  // Atomicity, not ordering: both confirmations run at once and the store decides. The Lua GET+DEL
  // returns the record to exactly one caller, so the loser has nothing to consume and cannot set a
  // password.
  it("#167: two concurrent confirmations of one link — exactly one wins", async () => {
    const app = await buildApp(authRoutes, "/v1/auth");
    wireRedisStore();
    prismaMock.parent.update.mockResolvedValue({ id: "parent-1" });

    const token = await requestResetToken(app);
    const [a, b] = await Promise.all([confirmReset(app, token), confirmReset(app, token)]);
    expect([a.statusCode, b.statusCode].sort()).toEqual([200, 401]);
    expect(parentWritesOf("passwordHash")).toHaveLength(1);
    await app.close();
  });

  // The second variant in the issue: two requests leave two live tokens, and the older one keeps
  // working after the newer is used. Only the newest jti is honoured.
  it("#167: a second reset request supersedes the first link", async () => {
    const app = await buildApp(authRoutes, "/v1/auth");
    wireRedisStore();
    prismaMock.parent.update.mockResolvedValue({ id: "parent-1" });

    const older = await requestResetToken(app);
    // A second request inside the 60 s cooldown is answered without a new link (see the cooldown
    // tests), so supersession is exercised where it can happen: after the cooldown has expired.
    const realNow = Date.now();
    const clock = vi.spyOn(Date, "now").mockReturnValue(realNow + 61_000);
    const newer = await requestResetToken(app);
    clock.mockRestore();

    const oldAttempt = await confirmReset(app, older);
    expect(oldAttempt.statusCode).toBe(401);
    expect(oldAttempt.json().error).toBe("invalid_or_expired_token");
    expect(prismaMock.parent.update).not.toHaveBeenCalled();

    const newAttempt = await confirmReset(app, newer);
    expect(newAttempt.statusCode).toBe(200);
    expect(parentWritesOf("passwordHash")).toHaveLength(1);
    // Each request gets its own identity (before #167 two in the same second were the same JWT).
    expect(older).not.toBe(newer);
    await app.close();
  });

  // #167 review: the cooldown is what stops a stranger from repeatedly superseding a parent's newest
  // link (and flooding their inbox) — a lever the supersession rule creates. One link per address per
  // 60 s; inside the window the answer is the same `{ok:true}`, with no link and no email.
  it("#167: a second reset request inside the 60 s cooldown sends no new link", async () => {
    const app = await buildApp(authRoutes, "/v1/auth");
    const { store } = wireRedisStore();
    const realNow = Date.now();
    let now = realNow;
    const clock = vi.spyOn(Date, "now").mockImplementation(() => now);

    try {
      const first = await app.inject({
        method: "POST", url: "/v1/auth/reset/request", payload: { email: registerBody.email },
      });
      expect(first.statusCode).toBe(200);
      expect(capture.sent).toHaveLength(1);
      const firstLatest = store.get("reset:latest:parent-1");
      expect(firstLatest).toBeTruthy();
      // The claim is per address, keyed by the sha256 of the normalised (trimmed, lowercased) email.
      const cooldownKey = `reset:cooldown:${createHash("sha256").update(registerBody.email.toLowerCase()).digest("hex")}`;
      expect(store.get(cooldownKey)).toBe("1");

      capture.sent = [];
      now += 59_000;
      const during = await app.inject({
        method: "POST", url: "/v1/auth/reset/request", payload: { email: registerBody.email.toUpperCase() },
      });
      expect(during.statusCode).toBe(200);
      expect(during.json()).toEqual({ ok: true });
      expect(capture.sent).toHaveLength(0);
      // No new jti: the parent's newest link is untouched, so the earlier one stays the live one.
      expect(store.get("reset:latest:parent-1")).toBe(firstLatest);

      // After the cooldown, a request issues a new link and supersedes the old one.
      now += 2_000;
      const after = await app.inject({
        method: "POST", url: "/v1/auth/reset/request", payload: { email: registerBody.email },
      });
      expect(after.statusCode).toBe(200);
      expect(capture.sent).toHaveLength(1);
      expect(store.get("reset:latest:parent-1")).not.toBe(firstLatest);
    } finally {
      clock.mockRestore();
    }
    await app.close();
  });

  // The cooldown write runs before the lookup, so a Redis outage answers the same 503 for a known and
  // an unknown address — and the lookup is never reached, which is what makes the answers identical.
  // #167 review (G1/G2): a database blip after the claim used to answer 400 and leave the cooldown
  // burning, so the parent's retry inside the minute was told "sent" while nothing was sent. The
  // claim must be released on any failure past it.
  it("#167: a lookup failure releases the cooldown and answers 503, so the retry sends a link", async () => {
    const app = await buildApp(authRoutes, "/v1/auth");
    const { store } = wireRedisStore();
    const cooldownKey = `reset:cooldown:${createHash("sha256").update(registerBody.email.toLowerCase()).digest("hex")}`;
    capture.sent.length = 0;

    prismaMock.parent.findUnique.mockRejectedValueOnce(new Error("connection reset"));
    const failed = await app.inject({
      method: "POST", url: "/v1/auth/reset/request", payload: { email: registerBody.email },
    });
    // The production handler maps Prisma-shaped errors to 400; this one is not Prisma-shaped, but the
    // route must not depend on the handler for a contract status either way.
    expect(failed.statusCode).toBe(503);
    expect(failed.json().error).toBe("reset_unavailable");
    expect(store.has(cooldownKey)).toBe(false);
    expect(capture.sent).toHaveLength(0);

    // The retry inside the same minute is treated as a fresh request, not as "sent a moment ago".
    prismaMock.parent.findUnique.mockResolvedValue({ id: "parent-1", familyId: "fam-1", email: registerBody.email });
    const retry = await app.inject({
      method: "POST", url: "/v1/auth/reset/request", payload: { email: registerBody.email },
    });
    expect(retry.statusCode).toBe(200);
    expect(capture.sent).toHaveLength(1);
    expect(store.get(cooldownKey)).toBe("1");
    await app.close();
  });

  it("#167: a provider refusal answers ok but releases the cooldown for the retry", async () => {
    const app = await buildApp(authRoutes, "/v1/auth");
    const { store } = wireRedisStore();
    const cooldownKey = `reset:cooldown:${createHash("sha256").update(registerBody.email.toLowerCase()).digest("hex")}`;
    prismaMock.parent.findUnique.mockResolvedValue({ id: "parent-1", familyId: "fam-1", email: registerBody.email });
    capture.failNext = true;

    const res = await app.inject({
      method: "POST", url: "/v1/auth/reset/request", payload: { email: registerBody.email },
    });
    expect(res.statusCode).toBe(200);
    expect(res.json()).toEqual({ ok: true });
    expect(store.has(cooldownKey)).toBe(false);
    await app.close();
  });

  it("#167: a cooldown store outage is a 503 for a known and an unknown address alike", async () => {
    const app = await buildApp(authRoutes, "/v1/auth");
    const { store } = wireRedisStore();
    const redis = getRedis() as unknown as MockRedis;
    prismaMock.parent.findUnique.mockResolvedValue({ id: "parent-1", familyId: "fam-1", email: registerBody.email });

    redis.set.mockRejectedValueOnce(new Error("redis unavailable"));
    const known = await app.inject({
      method: "POST", url: "/v1/auth/reset/request", payload: { email: registerBody.email },
    });
    expect(known.statusCode).toBe(503);
    expect(known.json().error).toBe("reset_unavailable");
    expect(prismaMock.parent.findUnique).not.toHaveBeenCalled();

    prismaMock.parent.findUnique.mockResolvedValue(null);
    redis.set.mockRejectedValueOnce(new Error("redis unavailable"));
    const unknown = await app.inject({
      method: "POST", url: "/v1/auth/reset/request", payload: { email: "ghost@osratech.com" },
    });
    expect(unknown.statusCode).toBe(503);
    expect(unknown.json()).toEqual(known.json());
    expect(prismaMock.parent.findUnique).not.toHaveBeenCalled();
    // Nothing sent, nothing claimed.
    expect(capture.sent).toHaveLength(0);
    expect([...store.keys()].some((k) => k.startsWith("reset:cooldown:"))).toBe(false);
    await app.close();
  });

  // #162 made a 5xx from the counter bump retryable with the same token. The single-use consume
  // runs first, so a failure after it must restore the record with its remaining lifetime.
  it("#167: a transient update failure is a 503 with the token restored, not a 404", async () => {
    // Review API-8 answered 404 for any parent-update failure, which told the client its account was
    // gone on a transient database error and stopped the retry #162 promised. Only a genuinely
    // missing parent is a 404 now.
    const app = await buildApp(authRoutes, "/v1/auth");
    const { store } = wireRedisStore();
    prismaMock.parent.findUnique.mockResolvedValue({ id: "parent-1", familyId: "fam-1", email: registerBody.email, passwordHash: await argon2.hash(PASSWORD) });

    const token = await requestResetToken(app);
    const claims = app.jwt.decode<{ jti: string }>(token)!;
    // The only findUnique so far is the one /reset/request used; the confirm must not re-read.
    expect(prismaMock.parent.findUnique).toHaveBeenCalledTimes(1);

    prismaMock.parent.update.mockRejectedValueOnce(new Error("connection reset"));

    const failed = await confirmReset(app, token);
    expect(failed.statusCode).toBe(503);
    expect(failed.json().error).toBe("reset_unavailable");
    expect(prismaMock.parent.findUnique).toHaveBeenCalledTimes(1);
    expect(store.get(`reset:${claims.jti}`)).toBe("parent-1");

    const retry = await confirmReset(app, token);
    expect(retry.statusCode).toBe(200);
  });

  // #167 review, blocker 2: a Prisma-shaped error from the update used to be rethrown, and server.ts's
  // global handler maps anything matching /prisma|invocation/ to 400 invalid_input — a status no
  // client following #162 retries. The route must answer 503 itself, and the handler must still be
  // the one doing the mapping for anything that really does escape (asserted in the test below).
  it("#167: a Prisma-shaped update failure is a 503, not the handler's 400 invalid_input", async () => {
    const app = await buildApp(authRoutes, "/v1/auth");
    wireRedisStore();
    prismaMock.parent.findUnique.mockResolvedValue({ id: "parent-1", familyId: "fam-1", email: registerBody.email, passwordHash: await argon2.hash(PASSWORD) });

    const token = await requestResetToken(app);
    prismaMock.parent.update.mockRejectedValueOnce(
      new Prisma.PrismaClientKnownRequestError(
        "\nInvalid `prisma.parent.update()` invocation:\n\nCan't reach database server",
        { code: "P1001", clientVersion: "5.14.0" },
      ),
    );

    const failed = await confirmReset(app, token);
    expect(failed.statusCode).toBe(503);
    expect(failed.json()).toEqual({ error: "reset_unavailable" });
  });

  it("buildApp installs the production error handler (a Prisma-shaped rethrow is 400)", async () => {
    // Guards the pin above: without this, a 503 could pass because no handler is installed at all.
    const app = await buildApp(async (a) => {
      a.get("/boom", async () => {
        throw new Prisma.PrismaClientKnownRequestError(
          "\nInvalid `prisma.parent.update()` invocation:\n\nCan't reach database server",
          { code: "P1001", clientVersion: "5.14.0" },
        );
      });
    }, "/v1/test");
    const res = await app.inject({ method: "GET", url: "/v1/test/boom" });
    expect(res.statusCode).toBe(400);
    expect(res.json().error).toBe("invalid_input");
    await app.close();
  });

  it("#167: a deleted parent is a 404 decided from P2025, and the link is dead", async () => {
    const app = await buildApp(authRoutes, "/v1/auth");
    const { store } = wireRedisStore();
    prismaMock.parent.findUnique.mockResolvedValue({ id: "parent-1", familyId: "fam-1", email: registerBody.email, passwordHash: await argon2.hash(PASSWORD) });

    const token = await requestResetToken(app);
    const claims = app.jwt.decode<{ jti: string }>(token)!;

    // What Prisma raises when the row an update targets no longer exists.
    prismaMock.parent.update.mockRejectedValueOnce(
      new Prisma.PrismaClientKnownRequestError(
        "An operation failed because it depends on one or more records that were required but not found. Record to update not found.",
        { code: "P2025", clientVersion: "5.14.0" },
      ),
    );

    const gone = await confirmReset(app, token);
    expect(gone.statusCode).toBe(404);
    expect(gone.json().error).toBe("account_not_found");
    // Really gone: there is nobody to restore the record for.
    expect(store.has(`reset:${claims.jti}`)).toBe(false);
  });

  // #167 review, blocker 3: a database outage (the update and every later call fail) used to re-read
  // the parent, get `null` from `.catch(() => null)`, and answer 404 account_not_found — turning
  // "can't reach the database" into "account gone", deleting the link, and breaking the retry.
  it("#167: a database outage is a 503 with the link restored, and the retry succeeds after recovery", async () => {
    const app = await buildApp(authRoutes, "/v1/auth");
    const { store } = wireRedisStore();
    const passwordHash = await argon2.hash(PASSWORD);
    prismaMock.parent.findUnique.mockResolvedValue({ id: "parent-1", familyId: "fam-1", email: registerBody.email, passwordHash });

    const token = await requestResetToken(app);
    const claims = app.jwt.decode<{ jti: string }>(token)!;

    const outage = () =>
      new Prisma.PrismaClientKnownRequestError(
        "\nInvalid `prisma.parent.update()` invocation:\n\nCan't reach database server at `localhost:5432`",
        { code: "P1001", clientVersion: "5.14.0" },
      );
    prismaMock.parent.update.mockRejectedValueOnce(outage());
    // "Any subsequent call rejects": if the route re-reads the parent to classify the error, that
    // read fails too, and a `.catch(() => null)` would answer 404 here.
    prismaMock.parent.findUnique.mockRejectedValue(outage());

    const failed = await confirmReset(app, token);
    expect(failed.statusCode).toBe(503);
    expect(failed.json().error).toBe("reset_unavailable");
    expect(store.get(`reset:${claims.jti}`)).toBe("parent-1");

    // Recovery: the same link works on the retry #162 promises.
    prismaMock.parent.findUnique.mockResolvedValue({ id: "parent-1", familyId: "fam-1", email: registerBody.email, passwordHash });
    prismaMock.parent.update.mockResolvedValue({ id: "parent-1" });
    const retry = await confirmReset(app, token);
    expect(retry.statusCode).toBe(200);
    const retried = parentWritesOf("passwordHash").at(-1) as { data: { passwordHash: string } };
    expect(await argon2.verify(retried.data.passwordHash, "NewCorrectHorse12!")).toBe(true);
    await app.close();
  });

  // The consume itself failing is not a spent link: it is an unreachable store, so 503 — with no raw
  // Redis message in the body (it used to be a rethrow, and the handler leaked it as a 500 body).
  it("#167: an unreachable store on the consume is a 503, not a spent link", async () => {
    const app = await buildApp(authRoutes, "/v1/auth");
    const { store } = wireRedisStore();
    prismaMock.parent.findUnique.mockResolvedValue({ id: "parent-1", familyId: "fam-1", email: registerBody.email, passwordHash: await argon2.hash(PASSWORD) });

    const token = await requestResetToken(app);
    const claims = app.jwt.decode<{ jti: string }>(token)!;
    const redis = getRedis() as unknown as MockRedis;
    redis.eval.mockRejectedValueOnce(new Error("ERR unknown command 'getdel'"));

    const failed = await confirmReset(app, token);
    expect(failed.statusCode).toBe(503);
    expect(failed.json()).toEqual({ error: "reset_unavailable" });
    // The script never ran: nothing was consumed.
    expect(store.get(`reset:${claims.jti}`)).toBe("parent-1");
    await app.close();
  });

  // The remaining post-consume branches answer 503 explicitly too, so none of them depends on the
  // global handler (which would turn a Prisma-shaped message into a 400).
  it("#167: a store failure on the latest-jti read and a hashing failure are 503 with the link restored", async () => {
    const app = await buildApp(authRoutes, "/v1/auth");
    const { store } = wireRedisStore();
    prismaMock.parent.findUnique.mockResolvedValue({ id: "parent-1", familyId: "fam-1", email: registerBody.email, passwordHash: await argon2.hash(PASSWORD) });
    prismaMock.parent.update.mockResolvedValue({ id: "parent-1" });
    const redis = getRedis() as unknown as MockRedis;

    const token = await requestResetToken(app);
    const claims = app.jwt.decode<{ jti: string }>(token)!;

    redis.get.mockRejectedValueOnce(new Error("redis unavailable"));
    const latestFailed = await confirmReset(app, token);
    expect(latestFailed.statusCode).toBe(503);
    expect(latestFailed.json()).toEqual({ error: "reset_unavailable" });
    expect(store.get(`reset:${claims.jti}`)).toBe("parent-1");

    const hashSpy = vi.spyOn(argon2, "hash").mockRejectedValueOnce(new Error("argon2 unavailable"));
    const hashFailed = await confirmReset(app, token);
    hashSpy.mockRestore();
    expect(hashFailed.statusCode).toBe(503);
    expect(hashFailed.json()).toEqual({ error: "reset_unavailable" });
    expect(store.get(`reset:${claims.jti}`)).toBe("parent-1");
    expect(prismaMock.parent.update).not.toHaveBeenCalled();

    // The restored link still works once the dependencies are back.
    const retry = await confirmReset(app, token);
    expect(retry.statusCode).toBe(200);
    await app.close();
  });

  it("#167: a failed session revocation is a 5xx, then the retry with the same token succeeds and old sessions are dead", async () => {
    const app = await buildApp(authRoutes, "/v1/auth");
    const { store, ttls } = wireRedisStore();
    const passwordHash = await argon2.hash(PASSWORD);
    prismaMock.parent.findUnique.mockResolvedValue({ id: "parent-1", familyId: "fam-1", email: registerBody.email, passwordHash });
    prismaMock.parent.update.mockResolvedValue({ id: "parent-1" });

    const login = await app.inject({
      method: "POST",
      url: "/v1/auth/login",
      payload: { email: registerBody.email, password: PASSWORD },
    });
    expect(login.statusCode).toBe(200);
    const oldAccess = login.json().token as string;
    const oldRefresh = login.json().refreshToken as string;

    const token = await requestResetToken(app);
    const claims = app.jwt.decode<{ jti: string; exp: number }>(token)!;

    // Move the clock 60 s so the restored TTL is visibly the token's remaining life (840), not 900.
    const realNow = Date.now();
    const clock = vi.spyOn(Date, "now").mockReturnValue(realNow + 60_000);
    const redis = getRedis() as unknown as MockRedis;
    redis.incrby.mockRejectedValueOnce(new Error("redis unavailable"));
    const failed = await confirmReset(app, token);
    expect(failed.statusCode).toBe(503);
    expect(failed.json().error).toBe("reset_unavailable");
    // The password write landed and so did the counter's column bump; the failure was the cache write
    // after them. Both are real writes, so both are asserted instead of one collapsed count.
    expect(parentWritesOf("passwordHash")).toHaveLength(1);
    expect(sessionVersionWrites()).toBe(1);

    const key = `reset:${claims.jti}`;
    expect(store.get(key)).toBe("parent-1");
    expect(ttls.get(key)).toBe(claims.exp - Math.floor((realNow + 60_000) / 1000));
    clock.mockRestore();

    // The client retries the same link (what #162 promised), and this time the whole operation runs.
    const retry = await confirmReset(app, token);
    expect(retry.statusCode).toBe(200);
    expect(parentWritesOf("passwordHash")).toHaveLength(2);
    expect(sessionVersionWrites()).toBe(2);
    // Both effects of an `ok`: the new hash is stored, every session is revoked.
    const secondUpdate = parentWritesOf("passwordHash")[1] as { data: { passwordHash: string } };
    expect(await argon2.verify(secondUpdate.data.passwordHash, "NewCorrectHorse12!")).toBe(true);
    expect(store.get("auth:session-version:parent-1")).toBe("1");
    expect(store.has(`refresh:${createHash("sha256").update(oldRefresh).digest("hex")}`)).toBe(false);
    const oldAccessAfter = await app.inject({
      method: "POST",
      url: "/v1/auth/logout-all",
      headers: { authorization: `Bearer ${oldAccess}` },
    });
    expect(oldAccessAfter.statusCode).toBe(401);
    expect(oldAccessAfter.json().error).toBe("session_revoked");
    await app.close();
  });

  it("rotates refresh tokens: replaying a consumed token fails (401)", async () => {
    const app = await buildApp(authRoutes, "/v1/auth");
    const passwordHash = await argon2.hash(PASSWORD);
    prismaMock.parent.findUnique.mockResolvedValue({ id: "parent-1", familyId: "fam-1", passwordHash });
    // Refresh tokens live in Redis now: back the mock with a Map store.
    const { getRedis } = await import("../src/redis.js");
    const { MockRedis: MR } = await import("./helpers.js");
    const store = new Map<string, string>();
    const redis = getRedis() as unknown as InstanceType<typeof MR>;
    redis.get.mockImplementation(async (k: string) => store.get(k) ?? null);
    redis.set.mockImplementation(async (k: string, v: string) => { store.set(k, String(v)); return "OK"; });
    redis.del.mockImplementation(async (...ks: string[]) => ks.reduce((n, k) => n + (store.delete(k) ? 1 : 0), 0));
    redis.incrby.mockImplementation(async (k: string, n: number) => {
      const next = Number(store.get(k) ?? 0) + n;
      store.set(k, String(next));
      return next;
    });
    redis.sadd.mockImplementation(async () => 1);
    redis.srem.mockImplementation(async () => 1);
    redis.smembers.mockImplementation(async () => []);

    const login = await app.inject({
      method: "POST",
      url: "/v1/auth/login",
      payload: { email: registerBody.email, password: PASSWORD },
    });
    expect(login.statusCode).toBe(200);
    const { refreshToken } = login.json();

    const first = await app.inject({
      method: "POST",
      url: "/v1/auth/token/refresh",
      payload: { refreshToken },
    });
    expect(first.statusCode).toBe(200);
    expect(first.json().token).toBeTruthy();
    expect(first.json().refreshToken).toBeTruthy();
    expect(first.json().refreshToken).not.toBe(refreshToken);

    // Rotation works along the chain first: the rotated token is the valid one.
    const second = await app.inject({
      method: "POST",
      url: "/v1/auth/token/refresh",
      payload: { refreshToken: first.json().refreshToken },
    });
    expect(second.statusCode).toBe(200);

    // Rotation: the consumed token is invalidated and must fail on replay.
    const replay = await app.inject({
      method: "POST",
      url: "/v1/auth/token/refresh",
      payload: { refreshToken },
    });
    expect(replay.statusCode).toBe(401);
    expect(replay.json().error).toBe("refresh_token_reused"); // handoff item 1: consumed-token replay is flagged as theft

    // ...and the theft response kills the whole chain, including the newest refresh token (#158:
    // the record carries the sessions version it was issued at, so a token minted before the
    // revocation cannot mint a live session afterwards). Before #158 this returned 200.
    const afterTheft = await app.inject({
      method: "POST",
      url: "/v1/auth/token/refresh",
      payload: { refreshToken: second.json().refreshToken },
    });
    expect(afterTheft.statusCode).toBe(401);
    await app.close();
  });

  it("rejects unknown refresh tokens (401) and a missing token body (400)", async () => {
    const app = await buildApp(authRoutes, "/v1/auth");
    const unknown = await app.inject({
      method: "POST",
      url: "/v1/auth/token/refresh",
      payload: { refreshToken: "deadbeef".repeat(12) },
    });
    expect(unknown.statusCode).toBe(401);
    expect(unknown.json().error).toBe("invalid_refresh_token");

    const missing = await app.inject({ method: "POST", url: "/v1/auth/token/refresh", payload: {} });
    expect(missing.statusCode).toBe(400);
    await app.close();
  });

  // #608: the demo account a tester logs in with must say OSRA, never FamilyShield. This pins the
  // fixture so a planted revert of the email fails here rather than in a user-facing flow.
  it("#608: the demo fixture email is demo@osratech.com (no familyshield in the demo account)", () => {
    expect(registerBody.email).toBe("demo@osratech.com");
    expect(registerBody.email).not.toMatch(/familyshield/i);
  });

  it("commits durable session revocation and push-token retirement atomically, rolls back on DB write failure so retry succeeds, and reconciles cache + socket signal on Redis write failure", async () => {
    // Mutant A: run `parent.update` and `parentPushToken.deleteMany` outside a single `$transaction` ->
    // a failed `deleteMany` leaves `sessionVersion` incremented, invalidating the caller's retry while
    // `notifyParentsOfAlert` still delivers to surviving push rows.
    // Mutant B: drop `redis.del(sessionVersionKey)` or skip `publishFamilyEvent` when Redis fails after
    // the durable transaction has already committed -> stale cache marker or open sockets survive a committed revocation.
    const app = await buildApp(async (a) => {
      await a.register(authRoutes, { prefix: "/v1/auth" });
      await a.register(meRoutes, { prefix: "/v1/me" });
    });
    const { store } = wireRedisStore();
    const redis = getRedis() as unknown as MockRedis;
    const sentTokens: string[] = [];
    const provider: PushProvider = {
      platform: "android",
      async send(token: string, _message: PushMessage): Promise<PushResult> {
        sentTokens.push(token);
        return { ok: true };
      },
    };
    const iosProvider: PushProvider = {
      platform: "ios",
      async send(token: string, _message: PushMessage): Promise<PushResult> {
        sentTokens.push(token);
        return { ok: true };
      },
    };
    setPushProviders([provider, iosProvider]);

    try {
      const passwordHash = await argon2.hash(PASSWORD);
      let p1SessionVersion = 0;
      type PushRow = { id: string; parentId: string; token: string; platform: string; appVersion?: string; sessionVersion: number; createdAt: Date; lastSeenAt: Date };
      let pushRows = new Map<string, PushRow>();
      let rowSeq = 0;
      let failNextDeleteMany = false;
      const txClientOps: string[] = [];

      const makeParentReader = (versionReader: () => number) =>
        async ({ where }: { where: { id?: string; email?: string } }) => {
          if (where.email === registerBody.email || where.id === "parent-1") {
            return {
              id: "parent-1",
              familyId: "fam-1",
              email: registerBody.email,
              displayName: "Demo Parent",
              role: "owner",
              permissions: [],
              passwordHash,
              mfaEnabled: false,
              mfaSecret: null,
              sessionVersion: versionReader(),
            };
          }
          if (where.id === "parent-2") {
            return {
              id: "parent-2",
              familyId: "fam-1",
              email: "coparent@osratech.com",
              displayName: "Co Parent",
              role: "co-parent",
              permissions: [],
              passwordHash,
              mfaEnabled: false,
              mfaSecret: null,
              sessionVersion: 0,
            };
          }
          return null;
        };

      prismaMock.parent.findUnique.mockImplementation(makeParentReader(() => p1SessionVersion));
      prismaMock.parent.findMany.mockResolvedValue([{ id: "parent-1" }, { id: "parent-2" }]);
      prismaMock.digestPrefs.findUnique.mockResolvedValue(null);
      prismaMock.parentPushToken.findMany.mockImplementation(async ({ where }: { where: { parentId: string | { in: string[] } } }) => {
        const ids = typeof where.parentId === "string" ? [where.parentId] : where.parentId.in;
        return [...pushRows.values()].filter((r) => ids.includes(r.parentId));
      });

      // Transactional mock: stages mutations inside `tx` and commits them to durable state only if `fn(tx)` resolves.
      // Distinct `tx` methods also prove production code uses `tx` rather than the global `prisma` client.
      prismaMock.$transaction.mockImplementation(async (arg: unknown) => {
        if (typeof arg !== "function") return Promise.all(arg as Promise<unknown>[]);
        let stagedVersion = p1SessionVersion;
        const stagedPushRows = new Map(pushRows);
        const tx = {
          ...prismaMock,
          $queryRaw: vi.fn(async () => {
            txClientOps.push("lock_parent");
            return [{ "?column?": 1 }];
          }),
          revokedToken: {
            ...prismaMock.revokedToken,
            findUnique: vi.fn(async () => null),
          },
          parent: {
            findMany: prismaMock.parent.findMany,
            findUnique: vi.fn(makeParentReader(() => stagedVersion)),
            update: vi.fn(async ({ where, data }: { where: { id: string }; data: Record<string, unknown> }) => {
              if (where.id === "parent-1" && data.sessionVersion !== undefined) {
                stagedVersion += 1;
                txClientOps.push("tx_increment_session_version");
              }
              return { id: where.id, familyId: "fam-1", sessionVersion: stagedVersion };
            }),
          },
          parentPushToken: {
            findMany: prismaMock.parentPushToken.findMany,
            upsert: vi.fn(async ({ where, create, update }: {
              where: { token: string };
              create: { parentId: string; token: string; platform: string; appVersion?: string; sessionVersion: number };
              update: { parentId: string; platform: string; appVersion?: string; sessionVersion: number; lastSeenAt: Date };
            }) => {
              txClientOps.push(`tx_upsert_push_token:${create.parentId}`);
              const existing = stagedPushRows.get(where.token);
              if (existing) {
                const next: PushRow = {
                  ...existing,
                  parentId: update.parentId,
                  platform: update.platform,
                  appVersion: update.appVersion,
                  sessionVersion: update.sessionVersion,
                  lastSeenAt: update.lastSeenAt,
                };
                stagedPushRows.set(where.token, next);
                return next;
              }
              const createdAt = new Date("2026-11-27T05:00:00Z");
              const created: PushRow = {
                id: `pt-${++rowSeq}`,
                parentId: create.parentId,
                token: create.token,
                platform: create.platform,
                appVersion: create.appVersion,
                sessionVersion: create.sessionVersion,
                createdAt,
                lastSeenAt: createdAt,
              };
              stagedPushRows.set(where.token, created);
              return created;
            }),
            deleteMany: vi.fn(async ({ where }: { where: { parentId?: string; token?: string; sessionVersion?: { lt: number } } }) => {
              txClientOps.push(`tx_delete_push_tokens:${where.parentId ?? ""}:${where.sessionVersion?.lt ?? "all"}`);
              if (failNextDeleteMany) {
                failNextDeleteMany = false;
                throw new Error("db write failed");
              }
              let removed = 0;
              for (const [tok, row] of [...stagedPushRows.entries()]) {
                if (where.parentId !== undefined && row.parentId !== where.parentId) continue;
                if (where.token !== undefined && row.token !== where.token) continue;
                if (where.sessionVersion?.lt !== undefined && row.sessionVersion >= where.sessionVersion.lt) continue;
                stagedPushRows.delete(tok);
                removed += 1;
              }
              return { count: removed };
            }),
          },
        };
        const result = await (arg as (client: unknown) => Promise<unknown>)(tx);
        p1SessionVersion = stagedVersion;
        pushRows = stagedPushRows;
        return result;
      });

      const loginA = await app.inject({ method: "POST", url: "/v1/auth/login", payload: { email: registerBody.email, password: PASSWORD } });
      const loginB = await app.inject({ method: "POST", url: "/v1/auth/login", payload: { email: registerBody.email, password: PASSWORD } });
      expect(loginA.statusCode).toBe(200);
      expect(loginB.statusCode).toBe(200);
      const tokenA = loginA.json().token as string;
      const tokenB = loginB.json().token as string;
      const refreshB = loginB.json().refreshToken as string;

      expect((await app.inject({
        method: "POST",
        url: "/v1/me/push-token",
        headers: { authorization: `Bearer ${tokenA}` },
        payload: { token: "a".repeat(32), platform: "android" },
      })).statusCode).toBe(201);
      expect((await app.inject({
        method: "POST",
        url: "/v1/me/push-token",
        headers: { authorization: `Bearer ${tokenB}` },
        payload: { token: "b".repeat(32), platform: "ios" },
      })).statusCode).toBe(201);
      const coJwt = app.jwt.sign({ sub: "parent-2", familyId: "fam-1", role: "parent", sv: 0 });
      expect((await app.inject({
        method: "POST",
        url: "/v1/me/push-token",
        headers: { authorization: `Bearer ${coJwt}` },
        payload: { token: "c".repeat(32), platform: "android" },
      })).statusCode).toBe(201);
      expect(pushRows.size).toBe(3);

      // Single-session `/logout` leaves sibling push registrations untouched.
      const singleLogout = await app.inject({
        method: "POST",
        url: "/v1/auth/logout",
        payload: { refreshToken: refreshB },
      });
      expect(singleLogout.statusCode).toBe(200);
      expect([...pushRows.values()].filter((r) => r.parentId === "parent-1")).toHaveLength(2);

      // Case 1: DB write failure on `parentPushToken.deleteMany` rolls back `Parent.sessionVersion` with it,
      // skips premature `session_revoked` socket publish, and leaves `tokenA` valid so the caller's retry completes cleanup.
      prismaMock.parent.update.mockClear();
      prismaMock.parentPushToken.deleteMany.mockClear();
      redis.publish.mockClear();
      txClientOps.length = 0;
      failNextDeleteMany = true;

      const failedLogoutAll = await app.inject({
        method: "POST",
        url: "/v1/auth/logout-all",
        headers: { authorization: `Bearer ${tokenA}` },
      });
      expect(failedLogoutAll.statusCode).toBe(500);
      expect(p1SessionVersion).toBe(0);
      expect(store.get("auth:session-version:parent-1")).toBe("0");
      expect([...pushRows.values()].filter((r) => r.parentId === "parent-1")).toHaveLength(2);
      expect(redis.publish).not.toHaveBeenCalled();
      // Neither write bypassed the transaction client.
      expect(prismaMock.parent.update).not.toHaveBeenCalled();
      expect(prismaMock.parentPushToken.deleteMany).not.toHaveBeenCalled();

      // Normal retry with the same bearer token `tokenA` succeeds and retires all `parent-1` push rows atomically.
      txClientOps.length = 0;
      const retriedLogoutAll = await app.inject({
        method: "POST",
        url: "/v1/auth/logout-all",
        headers: { authorization: `Bearer ${tokenA}` },
      });
      expect(retriedLogoutAll.statusCode).toBe(200);
      expect(retriedLogoutAll.json()).toEqual({ ok: true });
      expect(txClientOps).toEqual(["lock_parent", "tx_increment_session_version", "tx_delete_push_tokens:parent-1:1"]);
      expect(p1SessionVersion).toBe(1);
      expect(store.get("auth:session-version:parent-1")).toBe("1");
      expect([...pushRows.values()].filter((r) => r.parentId === "parent-1")).toHaveLength(0);
      expect([...pushRows.values()].filter((r) => r.parentId === "parent-2")).toHaveLength(1);
      expect(redis.publish).toHaveBeenCalledTimes(1);
      expect(JSON.parse(redis.publish.mock.calls[0][1] as string)).toMatchObject({
        type: "session_revoked",
        payload: { parentId: "parent-1" },
      });

      // Push delivery after atomic retirement sends only to `parent-2`, never to `parent-1`'s retired installations.
      sentTokens.length = 0;
      const alertRow = { id: "alert-92", childId: "child-1", severity: "critical", category: "sos", title: "SOS", body: "Help" };
      const pushAfterRetry = await notifyParentsOfAlert("fam-1", alertRow, "Alex");
      expect(pushAfterRetry).toEqual({ recipients: 1, delivered: 1, pruned: 0, skipped: null });
      expect(sentTokens).toEqual(["c".repeat(32)]);

      // Case 2: Redis cache write failure (`incrby` OOM) AFTER the durable transaction commits keeps both
      // `sessionVersion` and push-row retirement committed, drops the stale cache marker, still emits the
      // `session_revoked` socket signal, and leaves zero push delivery eligibility for `parent-1`.
      pushRows.clear();
      const loginC = await app.inject({ method: "POST", url: "/v1/auth/login", payload: { email: registerBody.email, password: PASSWORD } });
      expect(loginC.statusCode).toBe(200);
      const tokenC = loginC.json().token as string;
      expect((await app.inject({
        method: "POST",
        url: "/v1/me/push-token",
        headers: { authorization: `Bearer ${tokenC}` },
        payload: { token: "d".repeat(32), platform: "android" },
      })).statusCode).toBe(201);
      expect(pushRows.size).toBe(1);

      redis.publish.mockClear();
      redis.incrby.mockRejectedValueOnce(new Error("OOM command not allowed when used memory > 'maxmemory'"));
      const cacheFailLogout = await app.inject({
        method: "POST",
        url: "/v1/auth/logout-all",
        headers: { authorization: `Bearer ${tokenC}` },
      });
      expect(cacheFailLogout.statusCode).toBe(500);
      expect(p1SessionVersion).toBe(2);
      expect([...pushRows.values()]).toHaveLength(0);
      expect(store.get("auth:session-version:parent-1")).toBeUndefined();
      expect(redis.publish).toHaveBeenCalledTimes(1);
      expect(JSON.parse(redis.publish.mock.calls[0][1] as string)).toMatchObject({
        type: "session_revoked",
        payload: { parentId: "parent-1" },
      });

      sentTokens.length = 0;
      const pushAfterCacheFail = await notifyParentsOfAlert("fam-1", alertRow, "Alex");
      expect(pushAfterCacheFail).toEqual({ recipients: 0, delivered: 0, pruned: 0, skipped: "no_tokens" });
      expect(sentTokens).toEqual([]);

      // Next request with `tokenC` (`sv=1`) rebuilds the cache from `p1SessionVersion=2` and is refused with 401.
      const staleUse = await app.inject({
        method: "POST",
        url: "/v1/me/push-token",
        headers: { authorization: `Bearer ${tokenC}` },
        payload: { token: "e".repeat(32), platform: "android" },
      });
      expect(staleUse.statusCode).toBe(401);
      expect(staleUse.json()).toEqual({ error: "session_revoked" });
      expect(store.get("auth:session-version:parent-1")).toBe("2");
    } finally {
      setPushProviders([]);
      await app.close();
    }
  });

  it("serializes push-token registration with durable sessionVersion: rejects stale requests before upsert and preserves fresh-session registrations across the revocation cutoff", async () => {
    // Mutant A: validate `isParentSessionLive` after `upsert` (or delete by shared wall-clock `lastSeenAt`) ->
    // `upsert` is called for a stale pre-revocation request (`upsertedTokens` contains the stale token), and
    // concurrent writes at the same wall-clock timestamp collide.
    // Mutant B: run `parent.update` and `parentPushToken.deleteMany` with a gap outside the serialized lock ->
    // a fresh `sv=1` registration completing across the cutoff gets wiped by `deleteMany`.
    const app = await buildApp(async (a) => {
      await a.register(authRoutes, { prefix: "/v1/auth" });
      await a.register(meRoutes, { prefix: "/v1/me" });
    });
    wireRedisStore();
    const sentTokens: string[] = [];
    setPushProviders([{
      platform: "android",
      async send(token: string): Promise<PushResult> {
        sentTokens.push(token);
        return { ok: true };
      },
    }]);

    try {
      const passwordHash = await argon2.hash(PASSWORD);
      let p1SessionVersion = 0;
      const fixedClock = new Date("2026-11-27T05:30:00.000Z");
      type PushRow = { id: string; parentId: string; token: string; platform: string; appVersion?: string; sessionVersion: number; createdAt: Date; lastSeenAt: Date };
      const pushRows = new Map<string, PushRow>();
      const upsertedTokens: string[] = [];
      let rowSeq = 0;

      let onEnterDeleteMany: (() => Promise<void>) | null = null;
      let onEnterUpsert: (() => Promise<void>) | null = null;

      prismaMock.parent.findUnique.mockImplementation(async ({ where }: { where: { id?: string; email?: string } }) => {
        if (where.email === registerBody.email || where.id === "parent-1") {
          return {
            id: "parent-1",
            familyId: "fam-1",
            email: registerBody.email,
            displayName: "Demo Parent",
            role: "owner",
            permissions: [],
            passwordHash,
            mfaEnabled: false,
            mfaSecret: null,
            sessionVersion: p1SessionVersion,
          };
        }
        return null;
      });
      prismaMock.parent.findMany.mockResolvedValue([{ id: "parent-1" }]);
      prismaMock.digestPrefs.findUnique.mockResolvedValue(null);
      prismaMock.parent.update.mockImplementation(async ({ where, data }: { where: { id: string }; data: Record<string, unknown> }) => {
        if (where.id === "parent-1" && data.sessionVersion !== undefined) {
          p1SessionVersion += 1;
        }
        return { id: where.id, familyId: "fam-1", sessionVersion: p1SessionVersion };
      });
      prismaMock.parentPushToken.upsert.mockImplementation(async ({ where, create, update }: {
        where: { token: string };
        create: { parentId: string; token: string; platform: string; appVersion?: string; sessionVersion: number };
        update: { parentId: string; platform: string; appVersion?: string; sessionVersion: number; lastSeenAt: Date };
      }) => {
        upsertedTokens.push(where.token);
        if (onEnterUpsert) {
          const hook = onEnterUpsert;
          onEnterUpsert = null;
          await hook();
        }
        const existing = pushRows.get(where.token);
        if (existing) {
          const next: PushRow = {
            ...existing,
            parentId: update.parentId,
            platform: update.platform,
            appVersion: update.appVersion,
            sessionVersion: update.sessionVersion,
            lastSeenAt: fixedClock,
          };
          pushRows.set(where.token, next);
          return next;
        }
        const created: PushRow = {
          id: `pt-${++rowSeq}`,
          parentId: create.parentId,
          token: create.token,
          platform: create.platform,
          appVersion: create.appVersion,
          sessionVersion: create.sessionVersion,
          createdAt: fixedClock,
          lastSeenAt: fixedClock,
        };
        pushRows.set(where.token, created);
        return created;
      });
      prismaMock.parentPushToken.deleteMany.mockImplementation(async ({ where }: { where: { parentId?: string; token?: string } }) => {
        if (onEnterDeleteMany) {
          const hook = onEnterDeleteMany;
          onEnterDeleteMany = null;
          await hook();
        }
        let removed = 0;
        for (const [tok, row] of [...pushRows.entries()]) {
          if (where.parentId !== undefined && row.parentId !== where.parentId) continue;
          if (where.token !== undefined && row.token !== where.token) continue;
          pushRows.delete(tok);
          removed += 1;
        }
        return { count: removed };
      });
      prismaMock.parentPushToken.findMany.mockImplementation(async ({ where }: { where: { parentId: string | { in: string[] } } }) => {
        const ids = typeof where.parentId === "string" ? [where.parentId] : where.parentId.in;
        return [...pushRows.values()].filter((r) => ids.includes(r.parentId));
      });

      const login0 = await app.inject({ method: "POST", url: "/v1/auth/login", payload: { email: registerBody.email, password: PASSWORD } });
      expect(login0.statusCode).toBe(200);
      const tokenSv0 = login0.json().token as string;

      expect((await app.inject({
        method: "POST",
        url: "/v1/me/push-token",
        headers: { authorization: `Bearer ${tokenSv0}` },
        payload: { token: "1".repeat(32), platform: "android" },
      })).statusCode).toBe(201);

      // Subcase 1: `logout-all` holds the `Parent` serialization lock across `sessionVersion` 0->1 + `deleteMany`.
      // Both an already-authenticated stale `sv=0` registration and a `sv=1` registration queue behind that cutoff.
      let markDeleteEntered!: () => void;
      const deleteEntered = new Promise<void>((resolve) => { markDeleteEntered = resolve; });
      let releaseDelete!: () => void;
      const deleteGate = new Promise<void>((resolve) => { releaseDelete = resolve; });
      onEnterDeleteMany = async () => {
        markDeleteEntered();
        await deleteGate;
      };

      const logoutInFlight = app.inject({
        method: "POST",
        url: "/v1/auth/logout-all",
        headers: { authorization: `Bearer ${tokenSv0}` },
      });
      await deleteEntered;

      // Redis `auth:session-version:parent-1` is still "0" while the DB transaction is in flight, so both
      // `tokenSv0` (sv=0) and `tokenSv1` (sv=1) pass `requireParent` and queue on `withParentSessionLock("parent-1")`.
      const tokenSv1 = app.jwt.sign(
        { sub: "parent-1", familyId: "fam-1", role: "parent", familyRole: "owner", jti: "jti-fresh-sv1", sv: 1 },
        { expiresIn: "7d" },
      );
      upsertedTokens.length = 0;

      const staleRegInFlight = app.inject({
        method: "POST",
        url: "/v1/me/push-token",
        headers: { authorization: `Bearer ${tokenSv0}` },
        payload: { token: "2".repeat(32), platform: "android" },
      });
      const freshRegInFlight = app.inject({
        method: "POST",
        url: "/v1/me/push-token",
        headers: { authorization: `Bearer ${tokenSv1}` },
        payload: { token: "3".repeat(32), platform: "android" },
      });

      // Yield microtasks so both requests pass `requireParent` and line up at the serialized parent boundary.
      await Promise.resolve();
      await Promise.resolve();
      releaseDelete();

      const [logoutRes, staleRes, freshRes] = await Promise.all([logoutInFlight, staleRegInFlight, freshRegInFlight]);
      expect(logoutRes.statusCode).toBe(200);
      expect(staleRes.statusCode).toBe(401);
      expect(staleRes.json()).toEqual({ error: "session_revoked" });
      expect(freshRes.statusCode).toBe(201);

      // Stale `sv=0` registration was rejected BEFORE `upsert`; fresh `sv=1` registration was preserved!
      expect(upsertedTokens).toEqual(["3".repeat(32)]);
      expect([...pushRows.keys()]).toEqual(["3".repeat(32)]);

      const listed = await app.inject({
        method: "GET",
        url: "/v1/me/push-tokens",
        headers: { authorization: `Bearer ${tokenSv1}` },
      });
      expect(listed.statusCode).toBe(200);
      expect(listed.json().tokens).toHaveLength(1);

      sentTokens.length = 0;
      const alertRow = { id: "alert-92b", childId: "child-1", severity: "critical", category: "sos", title: "SOS", body: "Help" };
      expect(await notifyParentsOfAlert("fam-1", alertRow, "Alex")).toEqual({
        recipients: 1,
        delivered: 1,
        pruned: 0,
        skipped: null,
      });
      expect(sentTokens).toEqual(["3".repeat(32)]);

      // Subcase 2: a current-session registration that enters its locked transaction BEFORE `logout-all`
      // completes first, and `logout-all` then retires it atomically as `sessionVersion` advances 1->2.
      let markUpsertEntered!: () => void;
      const upsertEntered = new Promise<void>((resolve) => { markUpsertEntered = resolve; });
      let releaseUpsert!: () => void;
      const upsertGate = new Promise<void>((resolve) => { releaseUpsert = resolve; });
      onEnterUpsert = async () => {
        markUpsertEntered();
        await upsertGate;
      };

      const regBeforeRevoke = app.inject({
        method: "POST",
        url: "/v1/me/push-token",
        headers: { authorization: `Bearer ${tokenSv1}` },
        payload: { token: "4".repeat(32), platform: "android" },
      });
      await upsertEntered;

      const logoutQueuedBehindReg = app.inject({
        method: "POST",
        url: "/v1/auth/logout-all",
        headers: { authorization: `Bearer ${tokenSv1}` },
      });
      await Promise.resolve();
      releaseUpsert();

      const [regDone, logoutDone] = await Promise.all([regBeforeRevoke, logoutQueuedBehindReg]);
      expect(regDone.statusCode).toBe(201);
      expect(logoutDone.statusCode).toBe(200);
      expect(p1SessionVersion).toBe(2);
      expect(pushRows.size).toBe(0);
    } finally {
      setPushProviders([]);
      await app.close();
    }
  });

  it("returns MFA recovery codes on /mfa/verify even if push-row cleanup fails, while generation fencing blocks push delivery to pre-MFA registrations", async () => {
    // Mutant A: let `parentPushToken.deleteMany` failure abort `/v1/auth/mfa/verify` -> 500 loses the one-time plaintext recovery codes.
    // Mutant B: omit `sessionVersion` filtering in `notifyParentsOfAlert` -> surviving pre-MFA push rows still receive alert pushes after cleanup fails.
    const app = await buildApp(async (a) => {
      await a.register(authRoutes, { prefix: "/v1/auth" });
      await a.register(meRoutes, { prefix: "/v1/me" });
    });
    wireRedisStore();
    const sentTokens: string[] = [];
    setPushProviders([{
      platform: "android",
      async send(token: string): Promise<PushResult> {
        sentTokens.push(token);
        return { ok: true };
      },
    }]);

    try {
      const passwordHash = await argon2.hash(PASSWORD);
      let p1SessionVersion = 0;
      let p1MfaEnabled = false;
      let p1MfaSecret: string | null = null;
      type PushRow = { id: string; parentId: string; token: string; platform: string; sessionVersion: number; createdAt: Date; lastSeenAt: Date };
      const pushRows = new Map<string, PushRow>();

      prismaMock.parent.findUnique.mockImplementation(async ({ where }: { where: { id?: string; email?: string } }) => {
        if (where.email === registerBody.email || where.id === "parent-1") {
          return {
            id: "parent-1",
            familyId: "fam-1",
            email: registerBody.email,
            displayName: "Demo Parent",
            role: "owner",
            permissions: [],
            passwordHash,
            mfaEnabled: p1MfaEnabled,
            mfaSecret: p1MfaSecret,
            sessionVersion: p1SessionVersion,
          };
        }
        return null;
      });
      prismaMock.parent.findMany.mockImplementation(async () => [{ id: "parent-1", sessionVersion: p1SessionVersion }]);
      prismaMock.digestPrefs.findUnique.mockResolvedValue(null);
      prismaMock.parent.update.mockImplementation(async ({ data }: { data: Record<string, unknown> }) => {
        if (typeof data.mfaEnabled === "boolean") p1MfaEnabled = data.mfaEnabled;
        if ("mfaSecret" in data) p1MfaSecret = (data.mfaSecret as string | null) ?? null;
        if (data.sessionVersion !== undefined) p1SessionVersion += 1;
        return { id: "parent-1", familyId: "fam-1", mfaEnabled: p1MfaEnabled, mfaSecret: p1MfaSecret, sessionVersion: p1SessionVersion };
      });
      prismaMock.parentMfaRecoveryCode.count.mockResolvedValue(0);
      prismaMock.parentMfaRecoveryCode.deleteMany.mockResolvedValue({ count: 0 });
      prismaMock.parentMfaRecoveryCode.createMany.mockResolvedValue({ count: 10 });
      prismaMock.parentPushToken.upsert.mockImplementation(async ({ where, create, update }: {
        where: { token: string };
        create: { parentId: string; token: string; platform: string; sessionVersion: number };
        update: { parentId: string; platform: string; sessionVersion: number; lastSeenAt: Date };
      }) => {
        const now = new Date("2026-11-27T06:00:00Z");
        const row: PushRow = {
          id: "pt-mfa-1",
          parentId: create.parentId,
          token: where.token,
          platform: update.platform,
          sessionVersion: create.sessionVersion,
          createdAt: now,
          lastSeenAt: now,
        };
        pushRows.set(where.token, row);
        return row;
      });
      prismaMock.parentPushToken.findMany.mockImplementation(async () => [...pushRows.values()]);

      const loginRes = await app.inject({ method: "POST", url: "/v1/auth/login", payload: { email: registerBody.email, password: PASSWORD } });
      expect(loginRes.statusCode).toBe(200);
      const token0 = loginRes.json().token as string;

      expect((await app.inject({
        method: "POST",
        url: "/v1/me/push-token",
        headers: { authorization: `Bearer ${token0}` },
        payload: { token: "m".repeat(32), platform: "android" },
      })).statusCode).toBe(201);
      expect(pushRows.get("m".repeat(32))?.sessionVersion).toBe(0);

      const enrollRes = await app.inject({
        method: "POST",
        url: "/v1/auth/mfa/enroll",
        headers: { authorization: `Bearer ${token0}` },
        payload: {},
      });
      expect(enrollRes.statusCode).toBe(200);
      const totpSecret = enrollRes.json().secret as string;
      const counterNow = Math.floor(Date.now() / 1000 / 30);

      // Pre-commit failure path: if the MFA + recovery-hash + `sessionVersion` transaction fails before commit,
      // `/mfa/verify` returns 5xx, `sessionVersion` and `mfaEnabled` stay rolled back, and neither push cleanup
      // nor refresh-index sweep runs.
      const redis = getRedis() as unknown as MockRedis;
      const refresh0 = loginRes.json().refreshToken as string;
      prismaMock.parent.update.mockClear();
      prismaMock.parentPushToken.deleteMany.mockClear();
      redis.publish.mockClear();
      prismaMock.parentMfaRecoveryCode.createMany.mockRejectedValueOnce(new Error("db recovery insert failed"));
      const preCommitFail = await app.inject({
        method: "POST",
        url: "/v1/auth/mfa/verify",
        headers: { authorization: `Bearer ${token0}` },
        payload: { code: totpAtCounter(totpSecret, counterNow - 1) },
      });
      expect(preCommitFail.statusCode).toBe(500);
      // Roll back the staged `parent.update` from the mocked failure so durable state reflects transaction rollback:
      p1MfaEnabled = false;
      p1SessionVersion = 0;
      expect(prismaMock.parentPushToken.deleteMany).not.toHaveBeenCalled();
      expect(redis.publish).not.toHaveBeenCalled();
      // Pre-MFA refresh token was NOT swept because no durable cutoff committed:
      const preCommitRefreshCheck = await app.inject({
        method: "POST",
        url: "/v1/auth/token/refresh",
        payload: { refreshToken: refresh0 },
      });
      expect(preCommitRefreshCheck.statusCode).toBe(200);
      const token0Rotated = preCommitRefreshCheck.json().token as string;

      // Post-commit failure path: once the MFA + recovery-hash + `sessionVersion` transaction commits, even if
      // both `parentPushToken.deleteMany` AND Redis reconciliation (`incrby`) fail, `/mfa/verify` returns 200 + all 10 codes,
      // drops the stale cache marker via `DEL`, and fences pre-MFA push rows.
      const totpCode = totpAtCounter(totpSecret, counterNow);
      prismaMock.parentPushToken.deleteMany.mockRejectedValueOnce(new Error("transient push cleanup failure"));
      redis.incrby.mockRejectedValueOnce(new Error("OOM command not allowed"));
      const verifyRes = await app.inject({
        method: "POST",
        url: "/v1/auth/mfa/verify",
        headers: { authorization: `Bearer ${token0Rotated}` },
        payload: { code: totpCode },
      });
      expect(verifyRes.statusCode).toBe(200);
      expect(verifyRes.json().mfaEnabled).toBe(true);
      expect(verifyRes.json().recoveryCodes).toHaveLength(10);
      expect(p1SessionVersion).toBe(1);
      expect(await getRedis().get("auth:session-version:parent-1")).toBeNull();
      // The row is still in `pushRows` because `deleteMany` failed once...
      expect(pushRows.size).toBe(1);

      // Conditional cleanup in `notifyParentsOfAlert`: if a new `sv=1` registration updates `pt-mfa-1` in place
      // right before `deleteMany` executes, `sessionVersion: { lt: 1 }` preserves the upgraded row!
      prismaMock.parentPushToken.deleteMany.mockImplementationOnce(async ({ where }: {
        where: { OR?: Array<{ id: string; parentId: string; sessionVersion: { lt: number } }> };
      }) => {
        expect(where.OR).toEqual([{ id: "pt-mfa-1", parentId: "parent-1", sessionVersion: { lt: 1 } }]);
        // Simulate concurrent in-place `upsert` upgrading `pt-mfa-1` to `sessionVersion = 1` before `deleteMany` lands:
        const current = pushRows.get("m".repeat(32))!;
        pushRows.set("m".repeat(32), { ...current, sessionVersion: 1 });
        let removed = 0;
        for (const [tok, row] of [...pushRows.entries()]) {
          const matched = (where.OR ?? []).some(
            (clause) => row.id === clause.id && row.parentId === clause.parentId && row.sessionVersion < clause.sessionVersion.lt,
          );
          if (matched) {
            pushRows.delete(tok);
            removed += 1;
          }
        }
        return { count: removed };
      });
      const alertRow = { id: "alert-mfa", childId: "child-1", severity: "critical", category: "sos", title: "SOS", body: "Help" };
      const outcome = await notifyParentsOfAlert("fam-1", alertRow, "Alex");
      expect(outcome).toEqual({ recipients: 0, delivered: 0, pruned: 0, skipped: "no_tokens" });
      expect(sentTokens).toEqual([]);
      // Upgraded `sessionVersion=1` row survived the stale snapshot's conditional cleanup and delivers on the next alert!
      expect(pushRows.get("m".repeat(32))?.sessionVersion).toBe(1);
      // Any row belonging to a parent missing from the eligible snapshot (e.g. ineligible guardian) is excluded, never defaulted to version 0:
      pushRows.set("g".repeat(32), {
        id: "pt-ineligible-guardian",
        parentId: "guardian-no-alerts",
        token: "g".repeat(32),
        platform: "android",
        sessionVersion: 0,
        createdAt: new Date("2026-11-27T06:00:00Z"),
        lastSeenAt: new Date("2026-11-27T06:00:00Z"),
      });
      const nextOutcome = await notifyParentsOfAlert("fam-1", alertRow, "Alex");
      expect(nextOutcome).toEqual({ recipients: 1, delivered: 1, pruned: 0, skipped: null });
      expect(sentTokens).toEqual(["m".repeat(32)]);
    } finally {
      setPushProviders([]);
      await app.close();
    }
  });

  it("preserves current-generation sign-in and refresh across retireRefreshIndex cleanup and rejects sv-less push registrations", async () => {
    // Mutant A: sweep `refresh:index:<parentId>` unconditionally without checking `rec.sv < cutoffVersion` ->
    // a current-generation login created after the `Parent.sessionVersion` bump loses its refresh token (`401`).
    // Mutant B: admit `sv`-less JWT claims on `POST /v1/me/push-token` via Redis-only timestamp fallback ->
    // a claim without durable `sv` stamps a row at `durableVersion`.
    const app = await buildApp(async (a) => {
      await a.register(authRoutes, { prefix: "/v1/auth" });
      await a.register(meRoutes, { prefix: "/v1/me" });
    });
    wireRedisStore();
    const redis = getRedis() as unknown as MockRedis;

    try {
      const passwordHash = await argon2.hash(PASSWORD);
      let p1SessionVersion = 0;
      const upserts: unknown[] = [];

      prismaMock.parent.findUnique.mockImplementation(async ({ where }: { where: { id?: string; email?: string } }) => {
        if (where.email === registerBody.email || where.id === "parent-1") {
          return {
            id: "parent-1",
            familyId: "fam-1",
            email: registerBody.email,
            displayName: "Demo Parent",
            role: "owner",
            permissions: [],
            passwordHash,
            mfaEnabled: false,
            mfaSecret: null,
            sessionVersion: p1SessionVersion,
          };
        }
        return null;
      });
      prismaMock.parent.update.mockImplementation(async ({ data }: { data: Record<string, unknown> }) => {
        if (data.sessionVersion !== undefined) p1SessionVersion += 1;
        return { id: "parent-1", familyId: "fam-1", sessionVersion: p1SessionVersion };
      });
      prismaMock.parentPushToken.upsert.mockImplementation(async (args: unknown) => {
        upserts.push(args);
        return { id: "pt-1", platform: "android", createdAt: new Date("2026-11-27T06:00:00Z") };
      });

      // 1. Legacy `sv`-less claim is accepted ONLY while `Parent.sessionVersion === 0` (stamping `sessionVersion: 0`),
      // and is durably refused once `Parent.sessionVersion > 0` even if Redis `invalid-before` is absent!
      const legacyNoSv = app.jwt.sign({ sub: "parent-1", familyId: "fam-1", role: "parent", jti: "legacy-jti" }, { expiresIn: "7d" });
      const legacyAtZero = await app.inject({
        method: "POST",
        url: "/v1/me/push-token",
        headers: { authorization: `Bearer ${legacyNoSv}` },
        payload: { token: "z".repeat(32), platform: "android" },
      });
      expect(legacyAtZero.statusCode).toBe(201);
      expect(upserts).toHaveLength(1);

      // 2. Old session signs in (`sv=0`), then `logout-all` bumps `sessionVersion` to 1. Before `retireRefreshIndex`
      // reads `smembers("refresh:index:parent-1")`, a fresh current-generation `POST /v1/auth/login` (`sv=1`) completes!
      const loginOld = await app.inject({ method: "POST", url: "/v1/auth/login", payload: { email: registerBody.email, password: PASSWORD } });
      expect(loginOld.statusCode).toBe(200);
      const tokenOld = loginOld.json().token as string;
      const refreshOld = loginOld.json().refreshToken as string;

      const baseSmembers = redis.smembers.getMockImplementation()!;
      let freshRefreshDuringSweep = "";
      let interceptOnce = true;
      redis.smembers.mockImplementation(async (key: string) => {
        if (interceptOnce && key === "refresh:index:parent-1") {
          interceptOnce = false;
          const loginFresh = await app.inject({
            method: "POST",
            url: "/v1/auth/login",
            payload: { email: registerBody.email, password: PASSWORD },
          });
          expect(loginFresh.statusCode).toBe(200);
          freshRefreshDuringSweep = loginFresh.json().refreshToken as string;
        }
        return baseSmembers(key);
      });

      const logoutRes = await app.inject({
        method: "POST",
        url: "/v1/auth/logout-all",
        headers: { authorization: `Bearer ${tokenOld}` },
      });
      expect(logoutRes.statusCode).toBe(200);
      expect(freshRefreshDuringSweep).toBeTruthy();

      // Clear Redis `invalid-before` to simulate eviction: with `p1SessionVersion === 1`, the `sv`-less claim is
      // durably refused at registration without touching `upsert` (never stamped with `durableVersion = 1`)!
      await redis.del("auth:invalid-before:parent-1");
      upserts.length = 0;
      const legacyAfterBump = await app.inject({
        method: "POST",
        url: "/v1/me/push-token",
        headers: { authorization: `Bearer ${legacyNoSv}` },
        payload: { token: "l".repeat(32), platform: "android" },
      });
      expect(legacyAfterBump.statusCode).toBe(401);
      expect(legacyAfterBump.json()).toEqual({ error: "session_revoked" });
      expect(upserts).toHaveLength(0);

      // Old `sv=0` refresh token was retired by the sweep (`refresh_token_reused`), while the fresh `sv=1`
      // refresh token survived the sweep and rotates cleanly (`200`)!
      const oldRefreshAttempt = await app.inject({
        method: "POST",
        url: "/v1/auth/token/refresh",
        payload: { refreshToken: refreshOld },
      });
      expect(oldRefreshAttempt.statusCode).toBe(401);

      const freshRefreshAttempt = await app.inject({
        method: "POST",
        url: "/v1/auth/token/refresh",
        payload: { refreshToken: freshRefreshDuringSweep },
      });
      expect(freshRefreshAttempt.statusCode).toBe(200);
      expect(freshRefreshAttempt.json().token).toBeTruthy();
      expect(freshRefreshAttempt.json().refreshToken).toBeTruthy();
    } finally {
      await app.close();
    }
  });
});
