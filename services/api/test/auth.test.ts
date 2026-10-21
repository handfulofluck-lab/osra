import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { createHash } from "node:crypto";
import type { FastifyInstance } from "fastify";
import argon2 from "argon2";
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
  async send(message: EmailMessage) {
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
  const sets = new Map<string, Set<string>>();
  redis.get.mockImplementation(async (k: string) => store.get(k) ?? null);
  redis.set.mockImplementation(async (k: string, v: string, ...args: unknown[]) => {
    store.set(k, String(v));
    const ex = args.indexOf("EX");
    if (ex !== -1 && typeof args[ex + 1] === "number") ttls.set(k, args[ex + 1] as number);
    return "OK";
  });
  redis.getdel.mockImplementation(async (k: string) => {
    const v = store.get(k) ?? null;
    store.delete(k);
    ttls.delete(k);
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

describe("auth routes", () => {
  beforeEach(() => {
    resetPrismaMock();
    capture.sent = [];
    setEmailSender(capture);
    // The Redis instance is a module singleton in this file: give every test the empty-store
    // defaults so an implementation from one test cannot leak into the next.
    const redis = getRedis() as unknown as MockRedis;
    redis.get.mockImplementation(async () => null);
    redis.getdel.mockImplementation(async () => null);
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
    expect(prismaMock.parent.update).toHaveBeenCalledTimes(1);
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
    expect(prismaMock.parent.update).toHaveBeenCalledTimes(1);

    const replay = await confirmReset(app, token);
    expect(replay.statusCode).toBe(401);
    expect(replay.json().error).toBe("invalid_or_expired_token");
    // Consumed before the hash/DB work: the replay changed nothing.
    expect(prismaMock.parent.update).toHaveBeenCalledTimes(1);
    await app.close();
  });

  // Atomicity, not ordering: both confirmations run at once and the store decides. `GETDEL` returns
  // the record to exactly one caller, so the loser has nothing to consume and cannot set a password.
  it("#167: two concurrent confirmations of one link — exactly one wins", async () => {
    const app = await buildApp(authRoutes, "/v1/auth");
    wireRedisStore();
    prismaMock.parent.update.mockResolvedValue({ id: "parent-1" });

    const token = await requestResetToken(app);
    const [a, b] = await Promise.all([confirmReset(app, token), confirmReset(app, token)]);
    expect([a.statusCode, b.statusCode].sort()).toEqual([200, 401]);
    expect(prismaMock.parent.update).toHaveBeenCalledTimes(1);
    await app.close();
  });

  // The second variant in the issue: two requests leave two live tokens, and the older one keeps
  // working after the newer is used. Only the newest jti is honoured.
  it("#167: a second reset request supersedes the first link", async () => {
    const app = await buildApp(authRoutes, "/v1/auth");
    wireRedisStore();
    prismaMock.parent.update.mockResolvedValue({ id: "parent-1" });

    const older = await requestResetToken(app);
    const newer = await requestResetToken(app);

    const oldAttempt = await confirmReset(app, older);
    expect(oldAttempt.statusCode).toBe(401);
    expect(oldAttempt.json().error).toBe("invalid_or_expired_token");
    expect(prismaMock.parent.update).not.toHaveBeenCalled();

    const newAttempt = await confirmReset(app, newer);
    expect(newAttempt.statusCode).toBe(200);
    expect(prismaMock.parent.update).toHaveBeenCalledTimes(1);
    // Each request gets its own identity (before #167 two in the same second were the same JWT).
    expect(older).not.toBe(newer);
    await app.close();
  });

  // #162 made a 5xx from the counter bump retryable with the same token. The single-use consume
  // runs first, so a failure after it must restore the record with its remaining lifetime.
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
    expect(failed.statusCode).toBe(500);
    expect(prismaMock.parent.update).toHaveBeenCalledTimes(1);

    const key = `reset:${claims.jti}`;
    expect(store.get(key)).toBe("parent-1");
    expect(ttls.get(key)).toBe(claims.exp - Math.floor((realNow + 60_000) / 1000));
    clock.mockRestore();

    // The client retries the same link (what #162 promised), and this time the whole operation runs.
    const retry = await confirmReset(app, token);
    expect(retry.statusCode).toBe(200);
    expect(prismaMock.parent.update).toHaveBeenCalledTimes(2);
    // Both effects of an `ok`: the new hash is stored, every session is revoked.
    const secondUpdate = prismaMock.parent.update.mock.calls[1][0] as { data: { passwordHash: string } };
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
