import { beforeEach, describe, expect, it, vi } from "vitest";
import { authRoutes } from "../src/routes/auth.js";
import { inviteRoutes } from "../src/routes/invites.js";
import { rulesRoutes } from "../src/routes/rules.js";
import { familyRoutes } from "../src/routes/family.js";
import { alertsRoutes } from "../src/routes/alerts.js";
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
vi.mock("argon2", () => ({
  default: { verify: vi.fn(async () => true), hash: vi.fn(async () => "argon2$stub") },
}));

const PASSWORD = "CorrectHorseBatteryStaple!";
const OWNER = { id: "p1", familyId: "fam-1", email: "a@b.co", displayName: "A", role: "owner", permissions: [] as string[], mfaEnabled: false, mfaSecret: null, passwordHash: "h" };

/** Back the mocked Redis with a Map so keys written by one call are read by the next. */
function wireRedisStore() {
  const store = new Map<string, string>();
  const redis = getRedis() as unknown as MockRedis;
  redis.get.mockImplementation(async (k: string) => store.get(k) ?? null);
  redis.set.mockImplementation(async (k: string, v: string) => { store.set(k, String(v)); return "OK"; });
  redis.del.mockImplementation(async (...ks: string[]) => ks.reduce((n, k) => n + (store.delete(k) ? 1 : 0), 0));
  redis.smembers.mockResolvedValue([]);
  return store;
}

describe("parent sessions — jti on every token, invalid-before epoch (ADR-0014)", () => {
  let store: Map<string, string>;
  beforeEach(() => {
    resetPrismaMock();
    store = wireRedisStore();
    prismaMock.parent.findUnique.mockResolvedValue(OWNER);
  });

  it("login and register tokens carry a jti and familyRole", async () => {
    const app = await buildApp(authRoutes, "/v1/auth");
    const login = await app.inject({ method: "POST", url: "/v1/auth/login", payload: { email: "a@b.co", password: PASSWORD } });
    const claims = app.jwt.decode(login.json().token) as { jti?: string; role?: string; familyRole?: string };
    expect(claims.jti).toMatch(/^[0-9a-f]{32}$/);
    expect(claims.role).toBe("parent");
    expect(claims.familyRole).toBe("owner");
    await app.close();
  });

  it("logout-all (and password reset / MFA enable / theft, same path) kills the LIVE access token, not only the refresh token", async () => {
    const app = await buildApp(authRoutes, "/v1/auth");
    // A token issued one second before the revocation.
    const old = app.jwt.sign({ sub: "p1", familyId: "fam-1", role: "parent", jti: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", iat: Math.floor(Date.now() / 1000) - 1 }, { expiresIn: "7d" });
    const before = await app.inject({ method: "POST", url: "/v1/auth/logout-all", headers: { authorization: `Bearer ${old}` } });
    expect(before.statusCode).toBe(200);
    expect(store.get("auth:invalid-before:p1")).toBeTruthy();
    // The same token is now dead on a parent-gated route.
    const after = await app.inject({ method: "POST", url: "/v1/auth/logout-all", headers: { authorization: `Bearer ${old}` } });
    expect(after.statusCode).toBe(401);
    expect(after.json().error).toBe("session_revoked");
    // A token issued AFTER the revocation is fine.
    const fresh = app.jwt.sign({ sub: "p1", familyId: "fam-1", role: "parent", jti: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", iat: Math.floor(Date.now() / 1000) + 2 }, { expiresIn: "7d" });
    expect((await app.inject({ method: "POST", url: "/v1/auth/logout-all", headers: { authorization: `Bearer ${fresh}` } })).statusCode).toBe(200);
    await app.close();
  });

  it("single logout with the refresh token also revokes the access token issued with it", async () => {
    const app = await buildApp(authRoutes, "/v1/auth");
    const login = await app.inject({ method: "POST", url: "/v1/auth/login", payload: { email: "a@b.co", password: PASSWORD } });
    const { token, refreshToken } = login.json();
    const { jti } = app.jwt.decode(token) as { jti: string };
    expect((await app.inject({ method: "POST", url: "/v1/auth/logout-all", headers: { authorization: `Bearer ${token}` } })).statusCode).toBe(200);
    // (logout-all above also bumped invalid-before; use a second login to isolate the jti path)
    store.delete("auth:invalid-before:p1");
    const out = await app.inject({ method: "POST", url: "/v1/auth/logout", payload: { refreshToken } });
    expect(out.statusCode).toBe(200);
    expect(store.get(`revoked:token:${jti}`)).toBe("1");
    const dead = await app.inject({ method: "POST", url: "/v1/auth/logout-all", headers: { authorization: `Bearer ${token}` } });
    expect(dead.statusCode).toBe(401);
    await app.close();
  });
});

describe("family roles — co-parent tokens work, permissions are enforced (ADR-0014)", () => {
  beforeEach(() => {
    resetPrismaMock();
    wireRedisStore();
  });

  it("invite accept mints a token requireParent accepts (role=parent, familyRole=co-parent)", async () => {
    const app = await buildApp(inviteRoutes, "/v1/family");
    const redis = getRedis() as unknown as MockRedis;
    await redis.set("invite:inv-1", JSON.stringify({ familyId: "fam-2", email: "co@x.co", role: "co-parent", permissions: ["rules"] }));
    prismaMock.familyInvite.findUnique.mockResolvedValue({ id: "inv-1", familyId: "fam-2", email: "co@x.co", role: "co-parent", permissions: ["rules"], status: "pending" });
    prismaMock.parent.findUnique.mockResolvedValue({ ...OWNER, id: "p-co", email: "co@x.co", familyId: "fam-old" });
    prismaMock.parent.update.mockResolvedValue({ id: "p-co", familyId: "fam-2", role: "co-parent", permissions: ["rules"], email: "co@x.co", passwordHash: "h" });
    prismaMock.familyInvite.update.mockResolvedValue({});
    prismaMock.family.findUnique.mockResolvedValue({ id: "fam-2", name: "F2" });
    const res = await app.inject({ method: "POST", url: "/v1/family/invites/inv-1/accept", headers: authHeader(app, "fam-old", "p-co") });
    expect(res.statusCode).toBe(200);
    const claims = app.jwt.decode(res.json().token) as { role: string; familyRole: string; familyId: string; jti: string };
    expect(claims).toMatchObject({ role: "parent", familyRole: "co-parent", familyId: "fam-2" });
    expect(claims.jti).toMatch(/^[0-9a-f]{32}$/);

    // That token passes requireParent on a parent-only route (it used to be rejected: parent_role_required).
    const rules = await buildApp(rulesRoutes, "/v1/rules");
    prismaMock.parent.findUnique.mockResolvedValue({ id: "p-co", familyId: "fam-2", role: "co-parent", permissions: ["rules"] });
    prismaMock.child.findUnique.mockResolvedValue({ id: "child-2", familyId: "fam-2" });
    prismaMock.ruleSet.findUnique.mockResolvedValue({ childId: "child-2", appRules: [], routines: [] });
    const read = await rules.inject({ method: "GET", url: "/v1/rules/child-2", headers: { authorization: `Bearer ${res.json().token}` } });
    expect(read.statusCode).not.toBe(403);
    await rules.close();
    await app.close();
  });

  it("a guardian without the 'rules' permission cannot write rules (403 permission_required) but can read them", async () => {
    const app = await buildApp(rulesRoutes, "/v1/rules");
    prismaMock.parent.findUnique.mockResolvedValue({ id: "p-g", familyId: "fam-1", role: "guardian", permissions: ["alerts"] });
    prismaMock.child.findUnique.mockResolvedValue({ id: "child-1", familyId: "fam-1" });
    prismaMock.ruleSet.findUnique.mockResolvedValue({ childId: "child-1", appRules: [], routines: [] });
    const h = authHeader(app, "fam-1", "p-g");
    const write = await app.inject({ method: "PATCH", url: "/v1/rules/child-1", headers: h, payload: { dailyLimitMinutes: 60 } });
    expect(write.statusCode).toBe(403);
    expect(write.json()).toEqual({ error: "permission_required", permission: "rules" });
    expect(prismaMock.ruleSet.upsert).not.toHaveBeenCalled();
    const read = await app.inject({ method: "GET", url: "/v1/rules/child-1", headers: h });
    expect(read.statusCode).not.toBe(403);
    await app.close();
  });

  it("a co-parent WITH the 'alerts' permission can acknowledge an alert; without it 403", async () => {
    const app = await buildApp(alertsRoutes, "/v1/alerts");
    prismaMock.alert.findUnique.mockResolvedValue({ id: "al-1", childId: "child-1", child: { familyId: "fam-1" } });
    prismaMock.alert.update.mockResolvedValue({ id: "al-1", acknowledged: true });
    prismaMock.parent.findUnique.mockResolvedValue({ id: "p-co", familyId: "fam-1", role: "co-parent", permissions: ["alerts"] });
    expect((await app.inject({ method: "POST", url: "/v1/alerts/al-1/ack", headers: authHeader(app, "fam-1", "p-co") })).statusCode).toBe(200);
    prismaMock.parent.findUnique.mockResolvedValue({ id: "p-co", familyId: "fam-1", role: "co-parent", permissions: [] });
    expect((await app.inject({ method: "POST", url: "/v1/alerts/al-1/ack", headers: authHeader(app, "fam-1", "p-co") })).statusCode).toBe(403);
    await app.close();
  });

  it("only the owner can create children, erase a child or revoke consent (403 owner_role_required)", async () => {
    const app = await buildApp(familyRoutes, "/v1/family");
    prismaMock.parent.findUnique.mockResolvedValue({ id: "p-co", familyId: "fam-1", role: "co-parent", permissions: ["rules", "alerts", "location", "social", "devices"] });
    prismaMock.child.findUnique.mockResolvedValue({ id: "child-1", familyId: "fam-1" });
    const h = authHeader(app, "fam-1", "p-co");
    const create = await app.inject({ method: "POST", url: "/v1/family/children", headers: h, payload: { displayName: "X", birthYear: 2015 } });
    const erase = await app.inject({ method: "DELETE", url: "/v1/family/children/child-1", headers: h });
    const revoke = await app.inject({ method: "POST", url: "/v1/family/children/child-1/consent/revoke", headers: h, payload: {} });
    for (const r of [create, erase, revoke]) {
      expect(r.statusCode).toBe(403);
      expect(r.json().error).toBe("owner_role_required");
    }
    expect(prismaMock.child.delete).not.toHaveBeenCalled();
    await app.close();
  });
});
