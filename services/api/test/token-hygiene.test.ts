import { beforeEach, describe, expect, it, vi } from "vitest";
import { createHmac } from "node:crypto";
import { authRoutes } from "../src/routes/auth.js";
import { deviceRoutes } from "../src/routes/devices.js";
import { alertsRoutes } from "../src/routes/alerts.js";
import { getRedis } from "../src/redis.js";
import { MockRedis, authHeader, buildApp, deviceHeader, prismaMock, resetPrismaMock } from "./helpers.js";

vi.mock("../src/db.js", async () => {
  const { prismaMock } = await import("./helpers.js");
  return { prisma: prismaMock };
});
vi.mock("ioredis", async () => {
  const { MockRedis } = await import("./helpers.js");
  return { Redis: MockRedis };
});

vi.mock("argon2", () => ({
  default: { verify: vi.fn(async () => true), hash: vi.fn(async () => "argon2$stub") },
}));

/** Back the mocked Redis with a real Map so key lifecycle behaves like a store. */
function wireRedisStore() {
  const store = new Map<string, string>();
  const redis = getRedis() as unknown as MockRedis;
  redis.get.mockImplementation(async (k: string) => store.get(k) ?? null);
  redis.set.mockImplementation(async (k: string, v: string) => { store.set(k, String(v)); return "OK"; });
  redis.del.mockImplementation(async (...ks: string[]) => ks.reduce((n, k) => n + (store.delete(k) ? 1 : 0), 0));
  const sets = new Map<string, Set<string>>();
  redis.sadd.mockImplementation(async (k: string, ...ms: string[]) => {
    const s = sets.get(k) ?? new Set(); ms.forEach((m) => s.add(m)); sets.set(k, s); return s.size;
  });
  redis.srem.mockImplementation(async (k: string, ...ms: string[]) => {
    const s = sets.get(k); if (!s) return 0; ms.forEach((m) => s.delete(m)); return s.size;
  });
  redis.smembers.mockImplementation(async (k: string) => [...(sets.get(k) ?? [])]);
  return store;
}

const PASSWORD = "CorrectHorseBatteryStaple!";

describe("token hygiene — refresh store with reuse detection (handoff item 1)", () => {
  beforeEach(() => {
    resetPrismaMock();
    wireRedisStore();
    prismaMock.parent.findUnique.mockResolvedValue({ id: "p1", familyId: "fam-1", email: "a@b.co", mfaEnabled: false });
  });

  it("login issues a refresh token; refresh rotates it (old becomes invalid)", async () => {
    const app = await buildApp(authRoutes, "/v1/auth");
    const login = await app.inject({ method: "POST", url: "/v1/auth/login", payload: { email: "a@b.co", password: PASSWORD } });
    const rt = login.json().refreshToken;
    expect(rt).toBeTruthy();

    const rotated = await app.inject({ method: "POST", url: "/v1/auth/token/refresh", payload: { refreshToken: rt } });
    expect(rotated.statusCode).toBe(200);
    expect(rotated.json().refreshToken).not.toBe(rt);

    const oldReuse = await app.inject({ method: "POST", url: "/v1/auth/token/refresh", payload: { refreshToken: rt } });
    expect(oldReuse.statusCode).toBe(401);
    expect(oldReuse.json().error).toBe("refresh_token_reused");
    await app.close();
  });

  it("reuse detection kills every session of the parent (theft response)", async () => {
    const app = await buildApp(authRoutes, "/v1/auth");
    const l1 = await app.inject({ method: "POST", url: "/v1/auth/login", payload: { email: "a@b.co", password: PASSWORD } });
    const l2 = await app.inject({ method: "POST", url: "/v1/auth/login", payload: { email: "a@b.co", password: PASSWORD } });
    const r1 = await app.inject({ method: "POST", url: "/v1/auth/token/refresh", payload: { refreshToken: l1.json().refreshToken } });

    // Present the consumed r1 token again -> theft: r2 also revoked.
    const reuse = await app.inject({ method: "POST", url: "/v1/auth/token/refresh", payload: { refreshToken: l1.json().refreshToken } });
    expect(reuse.statusCode).toBe(401);
    expect(reuse.json().error).toBe("refresh_token_reused");
    const r2After = await app.inject({ method: "POST", url: "/v1/auth/token/refresh", payload: { refreshToken: l2.json().refreshToken } });
    expect(r2After.statusCode).toBe(401);
    // And the thief's rotated token from r1 is dead too.
    const thief = await app.inject({ method: "POST", url: "/v1/auth/token/refresh", payload: { refreshToken: r1.json().refreshToken } });
    expect(thief.statusCode).toBe(401);
    await app.close();
  });

  it("logout revokes a single refresh token; logout-all revokes every session", async () => {
    const app = await buildApp(authRoutes, "/v1/auth");
    const l1 = await app.inject({ method: "POST", url: "/v1/auth/login", payload: { email: "a@b.co", password: PASSWORD } });
    const l2 = await app.inject({ method: "POST", url: "/v1/auth/login", payload: { email: "a@b.co", password: PASSWORD } });

    const out = await app.inject({ method: "POST", url: "/v1/auth/logout", payload: { refreshToken: l1.json().refreshToken } });
    expect(out.statusCode).toBe(200);
    expect((await app.inject({ method: "POST", url: "/v1/auth/token/refresh", payload: { refreshToken: l1.json().refreshToken } })).statusCode).toBe(401);

    const all = await app.inject({ method: "POST", url: "/v1/auth/logout-all", headers: authHeader(app, "fam-1", "p1") });
    expect(all.statusCode).toBe(200);
    expect((await app.inject({ method: "POST", url: "/v1/auth/token/refresh", payload: { refreshToken: l2.json().refreshToken } })).statusCode).toBe(401);
    await app.close();
  });

  it("password reset and MFA enable revoke all sessions (handoff item 3)", async () => {
    const app = await buildApp(authRoutes, "/v1/auth");
    const login = await app.inject({ method: "POST", url: "/v1/auth/login", payload: { email: "a@b.co", password: PASSWORD } });
    const rt = login.json().refreshToken;

    const resetToken = app.jwt.sign({ sub: "p1", purpose: "password_reset" }, { expiresIn: "15m" });
    const reset = await app.inject({ method: "POST", url: "/v1/auth/reset/confirm", payload: { token: resetToken, password: "NewCorrectHorse!!" } });
    expect(reset.statusCode).toBe(200);
    expect((await app.inject({ method: "POST", url: "/v1/auth/token/refresh", payload: { refreshToken: rt } })).statusCode).toBe(401);

    // MFA enable path.
    const login2 = await app.inject({ method: "POST", url: "/v1/auth/login", payload: { email: "a@b.co", password: PASSWORD } });
    prismaMock.parent.findUnique.mockResolvedValue({ id: "p1", familyId: "fam-1", email: "a@b.co", mfaEnabled: false, mfaSecret: "JBSWY3DPEHPK3PXP" });
    const { totpAtCounter } = await import("../src/lib/totp.js");
    const code = totpAtCounter("JBSWY3DPEHPK3PXP", Math.floor(Date.now() / 1000 / 30));
    const mfa = await app.inject({ method: "POST", url: "/v1/auth/mfa/verify", headers: authHeader(app), payload: { code } });
    expect(mfa.statusCode).toBe(200);
    expect((await app.inject({ method: "POST", url: "/v1/auth/token/refresh", payload: { refreshToken: login2.json().refreshToken } })).statusCode).toBe(401);
    await app.close();
  });
});

describe("token hygiene — device JWT revocation (handoff item 4)", () => {
  beforeEach(() => {
    resetPrismaMock();
    wireRedisStore();
  });

  it("DELETE /v1/devices/:id revokes the device JWT", async () => {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    prismaMock.device.findUnique.mockResolvedValue({ id: "dev-1", childId: "child-1", child: { familyId: "fam-1" } });

    const del = await app.inject({ method: "DELETE", url: "/v1/devices/dev-1", headers: authHeader(app) });
    expect(del.statusCode).toBe(200);

    // A device JWT for that device now gets 401 on an authenticated read.
    const res = await app.inject({ method: "GET", url: "/v1/devices/dev-1", headers: deviceHeader(app) });
    expect(res.statusCode).toBe(401);
    expect(res.json().error).toBe("device_revoked");
    await app.close();
  });
});

describe("token hygiene — per-device HMAC secrets (handoff item 5)", () => {
  beforeEach(() => {
    resetPrismaMock();
    wireRedisStore();
    process.env.INTERNAL_HMAC_SECRET = "global-ai-engine-secret";
  });

  const sign = (body: string, secret: string) => createHmac("sha256", secret).update(body).digest("hex");

  it("a device-signed internal alert verifies against the DEVICE secret; the global secret no longer works for devices", async () => {
    const app = await buildApp(alertsRoutes, "/v1/alerts");
    prismaMock.child.findUnique.mockResolvedValue({ id: "child-1", familyId: "fam-1" });
    prismaMock.device.findUnique.mockResolvedValue({ id: "dev-1", internalSecret: "per-device-secret" });
    prismaMock.alert.create.mockResolvedValue({ id: "a-1" });

    const body = JSON.stringify({ childId: "child-1", deviceId: "dev-1", severity: "warning", category: "web_threat", title: "t", body: "b" });
    const withDeviceSecret = await app.inject({
      method: "POST",
      url: "/v1/alerts/internal",
      headers: { "content-type": "application/json", "x-familyshield-signature": sign(body, "per-device-secret") },
      payload: body,
    });
    expect(withDeviceSecret.statusCode).toBe(201);

    const withGlobalSecret = await app.inject({
      method: "POST",
      url: "/v1/alerts/internal",
      headers: { "content-type": "application/json", "x-familyshield-signature": sign(body, "global-ai-engine-secret") },
      payload: body,
    });
    expect(withGlobalSecret.statusCode).toBe(401);
    await app.close();
  });
});
