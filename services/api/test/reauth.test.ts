import { createHash } from "node:crypto";
import { Writable } from "node:stream";
import Fastify, { type FastifyInstance } from "fastify";
import fastifyJwt from "@fastify/jwt";
import argon2 from "argon2";
import type { Redis } from "ioredis";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { authRoutes } from "../src/routes/auth.js";
import { getRedis } from "../src/redis.js";
import { registerErrorHandler } from "../src/lib/errorHandler.js";
import { registerRateLimits } from "../src/lib/rateLimits.js";
import { registerReauthFailure } from "../src/lib/reauthSessionLimit.js";
import { sessionVersionKey } from "../src/lib/sessions.js";
import { generateTotpSecret, totpAtCounter } from "../src/lib/totp.js";
import { FakeRateLimitRedis, MockRedis, prismaMock, resetPrismaMock } from "./helpers.js";

vi.mock("../src/db.js", async () => {
  const { prismaMock } = await import("./helpers.js");
  return { prisma: prismaMock };
});
vi.mock("ioredis", async () => {
  const { MockRedis } = await import("./helpers.js");
  return { Redis: MockRedis };
});
vi.mock("argon2", () => ({
  default: { verify: vi.fn(), hash: vi.fn(async () => "synthetic-hash") },
}));

const PROOF = "synthetic-password-proof";
const PARENT = {
  id: "parent-1",
  familyId: "fam-1",
  email: "parent@example.invalid",
  displayName: "Synthetic Parent",
  role: "owner",
  permissions: [] as string[],
  passwordHash: "synthetic-password-hash",
  mfaEnabled: false,
  mfaSecret: null as string | null,
  sessionVersion: 7,
  lastLoginAt: new Date("2026-01-01T00:00:00Z"),
};
const NOW = Date.UTC(2026, 10, 15, 0, 0, 0);
const apps: FastifyInstance[] = [];
let store: Map<string, string>;

function wireRedisStore() {
  const redis = getRedis() as unknown as MockRedis;
  const store = new Map<string, string>();
  const ttls = new Map<string, number>();
  const sets = new Map<string, Set<string>>();
  redis.get.mockImplementation(async (key) => store.get(key) ?? null);
  redis.set.mockImplementation(async (key, value, ...args) => {
    if (args.includes("NX") && store.has(key)) return null;
    store.set(key, String(value));
    const ex = args.indexOf("EX");
    if (ex >= 0) ttls.set(key, Number(args[ex + 1]));
    return "OK";
  });
  redis.del.mockImplementation(async (...keys) => {
    let count = 0;
    for (const key of keys) {
      if (store.delete(key)) count++;
      sets.delete(key);
      ttls.delete(key);
    }
    return count;
  });
  redis.incr.mockImplementation(async (key) => {
    const next = Number(store.get(key) ?? 0) + 1;
    store.set(key, String(next));
    return next;
  });
  redis.incrby.mockImplementation(async (key, by) => {
    const next = Number(store.get(key) ?? 0) + by;
    store.set(key, String(next));
    return next;
  });
  redis.expire.mockImplementation(async (key, seconds) => {
    ttls.set(key, seconds);
    return 1;
  });
  redis.sadd.mockImplementation(async (key, ...members) => {
    const values = sets.get(key) ?? new Set<string>();
    for (const member of members) values.add(member);
    sets.set(key, values);
    return values.size;
  });
  redis.srem.mockImplementation(async (key, ...members) => {
    const values = sets.get(key);
    let count = 0;
    for (const member of members) if (values?.delete(member)) count++;
    return count;
  });
  redis.smembers.mockImplementation(async (key) => [...(sets.get(key) ?? [])]);
  return { store, ttls, sets };
}

async function makeApp(rateLimited = false, failAudit = false) {
  const logs: Array<Record<string, unknown>> = [];
  const stream = new Writable({
    write(chunk, _encoding, done) {
      for (const line of String(chunk).split("\n")) {
        if (line.trim()) logs.push(JSON.parse(line) as Record<string, unknown>);
      }
      done();
    },
  });
  const app = Fastify({ logger: { level: "info", stream } });
  apps.push(app);
  await app.register(fastifyJwt, { secret: "test-secret" });
  registerErrorHandler(app);
  if (failAudit) {
    app.addHook("onRequest", async (req) => {
      const originalInfo = req.log.info.bind(req.log);
      req.log.info = ((obj: Record<string, unknown>, msg?: unknown) => {
        if (obj.event === "parent_reauth") throw new Error("synthetic audit failure");
        return originalInfo(obj as never, msg as never);
      }) as typeof req.log.info;
    });
  }
  if (rateLimited) {
    await registerRateLimits(app, new FakeRateLimitRedis() as unknown as Redis);
  }
  await app.register(authRoutes, { prefix: "/v1/auth" });
  await app.ready();
  return { app, logs };
}

function sessionToken(app: FastifyInstance, jti = "jti-current", expiresIn: string | number = "1h") {
  return app.jwt.sign(
    { sub: PARENT.id, familyId: PARENT.familyId, role: "parent", familyRole: "owner", jti, sv: 7 },
    { expiresIn },
  );
}

function reauth(app: FastifyInstance, token: string, payload: Record<string, unknown> = { password: PROOF }) {
  return app.inject({
    method: "POST",
    url: "/v1/auth/reauth",
    headers: { authorization: `Bearer ${token}` },
    payload,
  });
}

function currentTotp(secret: string) {
  return totpAtCounter(secret, Math.floor(Date.now() / 30_000));
}

function wrongTotp(secret: string) {
  const counter = Math.floor(Date.now() / 30_000);
  for (let candidate = 0; candidate < 100; candidate++) {
    const code = String(candidate).padStart(6, "0");
    if ([counter - 1, counter, counter + 1].every((step) => totpAtCounter(secret, step) !== code)) return code;
  }
  throw new Error("no wrong TOTP found");
}

function seedRefresh(jti: string, tokenText: string) {
  const hash = createHash("sha256").update(tokenText).digest("hex");
  const redis = getRedis() as unknown as MockRedis;
  return { hash, tokenText, redis };
}

beforeEach(() => {
  resetPrismaMock();
  vi.spyOn(Date, "now").mockReturnValue(NOW);
  vi.mocked(argon2.verify).mockResolvedValue(true);
  prismaMock.parent.findUnique.mockResolvedValue({ ...PARENT });
  store = wireRedisStore().store;
  store.set(sessionVersionKey(PARENT.id), "7");
});

afterEach(async () => {
  await Promise.all(apps.splice(0).map((app) => app.close()));
  vi.restoreAllMocks();
});

describe("POST /v1/auth/reauth", () => {
  it("returns only 204 for a valid password and leaves login/session state unchanged", async () => {
    const { app, logs } = await makeApp();
    const res = await reauth(app, sessionToken(app));

    expect(res.statusCode).toBe(204);
    expect(res.body).toBe("");
    expect(prismaMock.parent.update).not.toHaveBeenCalled();
    expect(prismaMock.revokedToken.upsert).not.toHaveBeenCalled();
    expect(getRedis().set).not.toHaveBeenCalledWith(expect.stringMatching(/^refresh:/), expect.anything());
    const audit = logs.find((entry) => entry.event === "parent_reauth");
    expect(audit).toMatchObject({ parentId: PARENT.id, success: true });
    expect(audit?.reason).toBeUndefined();
    expect(typeof audit?.timestamp).toBe("string");
    for (const forbidden of ["password", "mfaCode", "recoveryCode", "token", "ip", "deviceName", "email"]) {
      expect(audit).not.toHaveProperty(forbidden);
    }
    expect(JSON.stringify(audit)).not.toContain(PROOF);
  });

  it("accepts a current TOTP once, then refuses its replay with the same 401", async () => {
    const secret = generateTotpSecret();
    prismaMock.parent.findUnique.mockResolvedValue({ ...PARENT, mfaEnabled: true, mfaSecret: secret });
    const { app, logs } = await makeApp();
    const token = sessionToken(app);
    const body = { password: PROOF, mfaCode: currentTotp(secret) };

    const first = await reauth(app, token, body);
    const second = await reauth(app, token, body);

    expect(first.statusCode).toBe(204);
    expect(second.statusCode).toBe(401);
    expect(second.json()).toEqual({ error: "reauth_failed" });
    const audits = logs.filter((entry) => entry.event === "parent_reauth");
    expect(audits.at(-1)).toMatchObject({ parentId: PARENT.id, success: false, reason: "totp_replay" });
    expect(prismaMock.parent.update).not.toHaveBeenCalled();
  });

  it("returns the uniform 401 for a wrong password", async () => {
    vi.mocked(argon2.verify).mockResolvedValue(false);
    const { app, logs } = await makeApp();
    const res = await reauth(app, sessionToken(app));
    expect(res.statusCode).toBe(401);
    expect(res.json()).toEqual({ error: "reauth_failed" });
    expect(logs.find((entry) => entry.event === "parent_reauth")).toMatchObject({ success: false, reason: "bad_password" });
  });

  it.each(["missing", "wrong", "malformed"])("returns the uniform 401 for a %s TOTP", async (kind) => {
    const secret = generateTotpSecret();
    prismaMock.parent.findUnique.mockResolvedValue({ ...PARENT, mfaEnabled: true, mfaSecret: secret });
    const { app } = await makeApp();
    const body: Record<string, unknown> = { password: PROOF };
    if (kind === "wrong") body.mfaCode = wrongTotp(secret);
    if (kind === "malformed") body.mfaCode = "12345";
    const res = await reauth(app, sessionToken(app), body);
    expect(res.statusCode).toBe(401);
    expect(res.json()).toEqual({ error: "reauth_failed" });
  });

  it("does not accept a recovery code as the current TOTP", async () => {
    const secret = generateTotpSecret();
    prismaMock.parent.findUnique.mockResolvedValue({ ...PARENT, mfaEnabled: true, mfaSecret: secret });
    const { app } = await makeApp();
    const res = await reauth(app, sessionToken(app), { password: PROOF, mfaCode: "ABCD-EFGH" });
    expect(res.statusCode).toBe(401);
    expect(res.json()).toEqual({ error: "reauth_failed" });
  });

  it("does not let password-only reauthentication bypass MFA re-enrollment", async () => {
    prismaMock.parent.findUnique.mockResolvedValue({ ...PARENT, mfaEnabled: true, mfaSecret: null });
    const { app } = await makeApp();
    const res = await reauth(app, sessionToken(app));
    expect(res.statusCode).toBe(401);
    expect(res.json()).toEqual({ error: "reauth_failed" });
  });

  it("refuses revoked and expired sessions before password verification", async () => {
    const { app } = await makeApp();
    const redis = getRedis() as unknown as MockRedis;
    const revoked = sessionToken(app);
    await redis.set("revoked:token:jti-current", "1");
    expect((await reauth(app, revoked)).statusCode).toBe(401);
    const expired = app.jwt.sign({
      sub: PARENT.id,
      familyId: PARENT.familyId,
      role: "parent",
      familyRole: "owner",
      jti: "jti-expired",
      sv: 7,
      exp: Math.floor(NOW / 1000) - 60,
    });
    expect((await reauth(app, expired)).statusCode).toBe(401);
    expect(argon2.verify).not.toHaveBeenCalled();
  });

  it("shares the auth bucket, maps its lockout to uniform 401 and audits rate_limited", async () => {
    const { app, logs } = await makeApp(true);
    const token = sessionToken(app);
    for (let i = 0; i < 20; i++) {
      expect((await reauth(app, token)).statusCode).toBe(204);
    }
    const limited = await reauth(app, token);
    expect(limited.statusCode).toBe(401);
    expect(limited.json()).toEqual({ error: "reauth_failed" });
    expect(argon2.verify).toHaveBeenCalledTimes(20);
    const audits = logs.filter((entry) => entry.event === "parent_reauth");
    expect(audits.at(-1)).toMatchObject({ parentId: PARENT.id, success: false, reason: "rate_limited" });
    expect(prismaMock.revokedToken.upsert).not.toHaveBeenCalled();
  });

  it("does not return success when the audit call fails", async () => {
    const { app } = await makeApp(false, true);
    const res = await reauth(app, sessionToken(app));
    expect(res.statusCode).not.toBe(204);
    expect(prismaMock.parent.update).not.toHaveBeenCalled();
  });
});

describe("the atomic per-session failure limit", () => {
  it("increments with the TTL in one MULTI and refuses a missing TTL", async () => {
    const redis = getRedis() as unknown as MockRedis;
    const counts = await Promise.all([
      registerReauthFailure(redis as unknown as Redis, "jti-current", 42),
      registerReauthFailure(redis as unknown as Redis, "jti-current", 42),
      registerReauthFailure(redis as unknown as Redis, "jti-current", 42),
      registerReauthFailure(redis as unknown as Redis, "jti-current", 42),
      registerReauthFailure(redis as unknown as Redis, "jti-current", 42),
    ]);
    expect(counts).toEqual([1, 2, 3, 4, 5]);
    expect(store.get("auth:reauth:fail:jti-current")).toBe("5");
    expect(redis.expire).toHaveBeenCalledTimes(5);
    expect(redis.expire).toHaveBeenCalledWith("auth:reauth:fail:jti-current", 42);
    expect(redis.get).not.toHaveBeenCalled();
    await expect(registerReauthFailure(redis as unknown as Redis, "jti-current", 0)).rejects.toThrow();
  });

  it("revokes once on failure five, kills only its refresh record and refuses later proof checks", async () => {
    const { app } = await makeApp();
    vi.mocked(argon2.verify).mockResolvedValue(false);
    const current = seedRefresh("jti-current", "synthetic-refresh-current");
    const other = seedRefresh("jti-other", "synthetic-refresh-other");
    await current.redis.set(`refresh:${current.hash}`, JSON.stringify({ parentId: PARENT.id, expiresAt: NOW + 60_000, jti: "jti-current", sv: 7 }));
    await other.redis.set(`refresh:${other.hash}`, JSON.stringify({ parentId: PARENT.id, expiresAt: NOW + 60_000, jti: "jti-other", sv: 7 }));
    const index = `refresh:index:${PARENT.id}`;
    await current.redis.sadd(index, current.hash, other.hash);
    const token = sessionToken(app);

    for (let failure = 1; failure <= 4; failure++) {
      expect((await reauth(app, token)).statusCode).toBe(401);
      expect(prismaMock.revokedToken.upsert).not.toHaveBeenCalled();
    }
    expect((await reauth(app, token)).statusCode).toBe(401);
    expect(prismaMock.revokedToken.upsert).toHaveBeenCalledTimes(1);
    expect(prismaMock.revokedToken.upsert.mock.calls[0][0].create.jti).toBe("jti-current");
    expect(prismaMock.parent.update).not.toHaveBeenCalled();
    expect(store.has(`refresh:${current.hash}`)).toBe(false);
    expect(store.has(`refresh:${other.hash}`)).toBe(true);

    const refresh = await app.inject({ method: "POST", url: "/v1/auth/token/refresh", payload: { refreshToken: current.tokenText } });
    expect(refresh.statusCode).toBe(401);
    expect(refresh.json()).toEqual({ error: "invalid_refresh_token" });
    const otherRefresh = await app.inject({ method: "POST", url: "/v1/auth/token/refresh", payload: { refreshToken: other.tokenText } });
    expect(otherRefresh.statusCode).toBe(200);
    expect(otherRefresh.json().token).toBeTruthy();

    expect((await reauth(app, token)).statusCode).toBe(401);
    expect(argon2.verify).toHaveBeenCalledTimes(5);
  });

  it("retries revocation after the first revoke throws", async () => {
    const { app } = await makeApp();
    vi.mocked(argon2.verify).mockResolvedValue(false);
    prismaMock.revokedToken.upsert.mockRejectedValueOnce(new Error("synthetic revocation failure"));
    const token = sessionToken(app);

    for (let failure = 1; failure <= 4; failure++) {
      expect((await reauth(app, token)).statusCode).toBe(401);
    }
    expect((await reauth(app, token)).statusCode).toBe(500);
    expect(prismaMock.revokedToken.upsert).toHaveBeenCalledTimes(1);

    const sixth = await reauth(app, token);
    expect(sixth.statusCode).toBe(401);
    expect(sixth.json()).toEqual({ error: "reauth_failed" });
    expect(prismaMock.revokedToken.upsert).toHaveBeenCalledTimes(2);
    expect(store.get("revoked:token:jti-current")).toBe("1");
  });

  it("allows exactly one revocation for five concurrent wrong proofs", async () => {
    const { app } = await makeApp();
    vi.mocked(argon2.verify).mockResolvedValue(false);
    const token = sessionToken(app);
    const responses = await Promise.all(Array.from({ length: 5 }, () => reauth(app, token)));
    expect(responses.map((res) => res.statusCode)).toEqual([401, 401, 401, 401, 401]);
    expect(prismaMock.revokedToken.upsert).toHaveBeenCalledTimes(1);
    expect(store.get("auth:reauth:fail:jti-current")).toBe("5");
    expect(getRedis().expire).toHaveBeenCalledWith("auth:reauth:fail:jti-current", 3600);
  });
});
