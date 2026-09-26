import { beforeEach, describe, expect, it, vi } from "vitest";
import { totpAtCounter } from "../src/lib/totp.js";
import { authRoutes } from "../src/routes/auth.js";
import { insightsRoutes } from "../src/routes/insights.js";
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
// argon2 verify is exercised in auth.test.ts; here we stub the hash so logins are fast.
vi.mock("argon2", () => ({
  default: { verify: vi.fn(async () => true), hash: vi.fn(async () => "argon2$stub") },
}));

describe("review fixes — auth hardening", () => {
  beforeEach(() => {
    resetPrismaMock();
  });

  it("login for an MFA-enabled parent requires a valid TOTP code (review 3.1)", async () => {
    const app = await buildApp(authRoutes, "/v1/auth");
    const secret = "JBSWY3DPEHPK3PXP"; // base32 test secret
    prismaMock.parent.findUnique.mockResolvedValue({ id: "p1", familyId: "fam-1", email: "a@b.co", mfaEnabled: true, mfaSecret: secret });

    const noCode = await app.inject({ method: "POST", url: "/v1/auth/login", payload: { email: "a@b.co", password: PASSWORD } });
    expect(noCode.statusCode).toBe(401);
    expect(noCode.json().error).toBe("mfa_required");

    const badCode = await app.inject({ method: "POST", url: "/v1/auth/login", payload: { email: "a@b.co", password: PASSWORD, code: "000000" } });
    expect(badCode.statusCode).toBe(401);

    const goodCode = totpAtCounter(secret, Math.floor(Date.now() / 1000 / 30));
    const ok = await app.inject({ method: "POST", url: "/v1/auth/login", payload: { email: "a@b.co", password: PASSWORD, code: goodCode } });
    expect(ok.statusCode).toBe(200);
    expect(ok.json().token).toBeTruthy();
    await app.close();
  });

  it("rejects TOTP replay within the validity window (review 3.1 replay protection)", async () => {
    const app = await buildApp(authRoutes, "/v1/auth");
    const secret = "JBSWY3DPEHPK3PXP";
    prismaMock.parent.findUnique.mockResolvedValue({ id: "p1", familyId: "fam-1", email: "a@b.co", mfaEnabled: true, mfaSecret: secret });
    const redis = (await import("../src/redis.js")).getRedis() as unknown as MockRedis;
    const counters = new Map<string, string>();
    redis.get.mockImplementation(async (k: string) => counters.get(k) ?? null);
    redis.set.mockImplementation(async (k: string, v: string) => { counters.set(k, v); return "OK"; });

    const code = totpAtCounter(secret, Math.floor(Date.now() / 1000 / 30));
    const first = await app.inject({ method: "POST", url: "/v1/auth/login", payload: { email: "a@b.co", password: PASSWORD, code } });
    expect(first.statusCode).toBe(200);
    const replay = await app.inject({ method: "POST", url: "/v1/auth/login", payload: { email: "a@b.co", password: PASSWORD, code } });
    expect(replay.statusCode).toBe(401);
    await app.close();
  });

  it("normalizes email case on register and login (review API-7)", async () => {
    const app = await buildApp(authRoutes, "/v1/auth");
    prismaMock.parent.findUnique.mockResolvedValueOnce(null);
    prismaMock.$transaction.mockImplementation(async (arg: unknown) =>
      typeof arg === "function" ? arg(prismaMock) : Promise.all(arg as Promise<unknown>[]),
    );
    prismaMock.family.create.mockResolvedValue({ id: "fam-1" });
    prismaMock.parent.create.mockResolvedValue({ id: "p1", email: "mixed@case.com" });
    const reg = await app.inject({
      method: "POST",
      url: "/v1/auth/register",
      payload: { email: "Mixed@Case.com", password: PASSWORD, displayName: "K", familyName: "F", region: "US" },
    });
    expect(reg.statusCode).toBe(201);
    expect(prismaMock.parent.findUnique).toHaveBeenCalledWith({ where: { email: "mixed@case.com" } });

    prismaMock.parent.findUnique.mockResolvedValue({ id: "p1", familyId: "fam-1", email: "mixed@case.com", mfaEnabled: false });
    const login = await app.inject({ method: "POST", url: "/v1/auth/login", payload: { email: "MIXED@case.COM", password: PASSWORD } });
    expect(login.statusCode).toBe(200);
    expect(prismaMock.parent.findUnique).toHaveBeenLastCalledWith({ where: { email: "mixed@case.com" } });
    await app.close();
  });

  it("parent access tokens now carry an expiry (review API-3)", async () => {
    const app = await buildApp(authRoutes, "/v1/auth");
    prismaMock.parent.findUnique.mockResolvedValue({ id: "p1", familyId: "fam-1", email: "a@b.co", mfaEnabled: false });
    const res = await app.inject({ method: "POST", url: "/v1/auth/login", payload: { email: "a@b.co", password: PASSWORD } });
    const decoded = app.jwt.verify<{ exp?: number }>(res.json().token);
    expect(decoded.exp).toBeGreaterThan(Date.now() / 1000 + 6 * 24 * 3600);
    await app.close();
  });
});

describe("review fixes — insights endpoint (3.3)", () => {
  beforeEach(() => {
    resetPrismaMock();
  });

  it("returns curated insight data for known apps and 404 otherwise", async () => {
    const app = await buildApp(insightsRoutes, "/v1/insights");
    const ok = await app.inject({ method: "GET", url: "/v1/insights/apps?packageId=com.discord", headers: authHeader(app) });
    expect(ok.statusCode).toBe(200);
    expect(ok.json().appName).toBe("Discord");
    expect(ok.json().risks.length).toBeGreaterThan(0);
    expect(ok.json().alternatives.length).toBeGreaterThan(0);

    const miss = await app.inject({ method: "GET", url: "/v1/insights/apps?packageId=com.unknown.app", headers: authHeader(app) });
    expect(miss.statusCode).toBe(404);

    const noAuth = await app.inject({ method: "GET", url: "/v1/insights/apps?packageId=com.discord" });
    expect(noAuth.statusCode).toBe(401);
    await app.close();
  });
});
