import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { createHash } from "node:crypto";
import type { FastifyInstance } from "fastify";
import argon2 from "argon2";
import { Prisma } from "@prisma/client";
import { authRoutes } from "../src/routes/auth.js";
import { decryptSecret, encryptSecret } from "../src/lib/secretVault.js";
import { totpAtCounter } from "../src/lib/totp.js";
import { setEmailSender, type EmailMessage, type EmailSender } from "../src/lib/email/index.js";
import { getRedis } from "../src/redis.js";
import { MockRedis, authHeader, buildApp, prismaMock, resetPrismaMock } from "./helpers.js";

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
  email: "demo@familyshield.dev",
  password: PASSWORD,
  displayName: "Demo Parent",
  familyName: "Demo Family",
  region: "US",
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
  // Atomic consume, mirroring the production Lua GET+DEL script (Redis 5.0 has no GETDEL).
  redis.eval.mockImplementation(async (_script: string, _n: number, key: string) => {
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
    redis.eval.mockImplementation(async () => null);
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
      payload: { email: "ghost@familyshield.dev" },
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
      method: "POST", url: "/v1/auth/reset/request", payload: { email: "ghost@familyshield.dev" },
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
});
