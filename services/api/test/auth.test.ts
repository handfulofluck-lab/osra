import { beforeEach, describe, expect, it, vi } from "vitest";
import argon2 from "argon2";
import { authRoutes } from "../src/routes/auth.js";
import { totpAtCounter } from "../src/lib/totp.js";
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

describe("auth routes", () => {
  beforeEach(() => {
    resetPrismaMock();
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
    expect(storedSecret).toBe(secret);

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

    // A purpose-scoped reset token sets the new password (argon2-hashed).
    prismaMock.parent.update.mockResolvedValue({ id: "parent-1" });
    const resetToken = app.jwt.sign({ sub: "parent-1", purpose: "password_reset" }, { expiresIn: "15m" });
    const ok = await app.inject({
      method: "POST",
      url: "/v1/auth/reset/confirm",
      payload: { token: resetToken, password: "NewCorrectHorse12!" },
    });
    expect(ok.statusCode).toBe(200);
    const updateArg = prismaMock.parent.update.mock.calls[0][0] as { data: { passwordHash: string } };
    expect(updateArg.data.passwordHash).not.toContain("NewCorrectHorse12!");
    expect(await argon2.verify(updateArg.data.passwordHash, "NewCorrectHorse12!")).toBe(true);
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

    // Rotation: the consumed token is invalidated and must fail on replay.
    const replay = await app.inject({
      method: "POST",
      url: "/v1/auth/token/refresh",
      payload: { refreshToken },
    });
    expect(replay.statusCode).toBe(401);
    expect(replay.json().error).toBe("refresh_token_reused"); // handoff item 1: consumed-token replay is flagged as theft

    // The rotated token is the only valid one now.
    const second = await app.inject({
      method: "POST",
      url: "/v1/auth/token/refresh",
      payload: { refreshToken: first.json().refreshToken },
    });
    expect(second.statusCode).toBe(200);
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
