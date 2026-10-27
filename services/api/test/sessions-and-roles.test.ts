import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { authRoutes } from "../src/routes/auth.js";
import { inviteRoutes } from "../src/routes/invites.js";
import { rulesRoutes } from "../src/routes/rules.js";
import { familyRoutes } from "../src/routes/family.js";
import { alertsRoutes } from "../src/routes/alerts.js";
import { getRedis } from "../src/redis.js";
import { invalidateSessionsBefore, isParentSessionLive } from "../src/lib/sessions.js";
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
  redis.incrby.mockImplementation(async (k: string, n: number) => {
    const next = Number(store.get(k) ?? 0) + n;
    store.set(k, String(next));
    return next;
  });
  redis.smembers.mockResolvedValue([]);
  redis.publish.mockClear(); // the session_revoked rows count this test's signals only
  return store;
}

describe("parent sessions — jti, sessions version / legacy epoch (ADR-0014, ADR-0025)", () => {
  let store: Map<string, string>;
  beforeEach(() => {
    resetPrismaMock();
    store = wireRedisStore();
    prismaMock.parent.findUnique.mockResolvedValue(OWNER);
  });
  afterEach(() => {
    vi.useRealTimers();
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

  // osra-security#4 item 3: every revocation path closes the parent's open sockets at once. The signal is
  // published from the shared revoke helper, so logout-all and the refresh-token theft response both send it.
  const revokedSignals = () =>
    (getRedis() as unknown as MockRedis).publish.mock.calls
      .filter(([, msg]) => JSON.parse(msg).type === "session_revoked")
      .map(([channel, msg]) => ({ channel, payload: JSON.parse(msg).payload }));

  it("logout-all signals the gateway to close that parent's sockets now", async () => {
    const app = await buildApp(authRoutes, "/v1/auth");
    const token = app.jwt.sign({ sub: "p1", familyId: "fam-1", role: "parent", jti: "cccccccccccccccccccccccccccccccc" }, { expiresIn: "7d" });
    const res = await app.inject({ method: "POST", url: "/v1/auth/logout-all", headers: { authorization: `Bearer ${token}` } });
    expect(res.statusCode).toBe(200);
    expect(revokedSignals()).toEqual([{ channel: "family:fam-1:events", payload: { parentId: "p1" } }]);
    await app.close();
  });

  it("the refresh-token theft response signals the gateway too, not only logout-all", async () => {
    const app = await buildApp(authRoutes, "/v1/auth");
    const login = await app.inject({ method: "POST", url: "/v1/auth/login", payload: { email: "a@b.co", password: PASSWORD } });
    const { refreshToken } = login.json() as { refreshToken: string };
    expect((await app.inject({ method: "POST", url: "/v1/auth/token/refresh", payload: { refreshToken } })).statusCode).toBe(200);
    expect(revokedSignals()).toEqual([]);
    const replay = await app.inject({ method: "POST", url: "/v1/auth/token/refresh", payload: { refreshToken } });
    expect(replay.json().error).toBe("refresh_token_reused");
    expect(revokedSignals()).toEqual([{ channel: "family:fam-1:events", payload: { parentId: "p1" } }]);
    await app.close();
  });

  it("a failed signal never fails the revocation: logout-all still answers 200 and the token is dead", async () => {
    (getRedis() as unknown as MockRedis).publish.mockRejectedValueOnce(new Error("redis down"));
    const app = await buildApp(authRoutes, "/v1/auth");
    const token = app.jwt.sign({ sub: "p1", familyId: "fam-1", role: "parent", jti: "dddddddddddddddddddddddddddddddd", iat: Math.floor(Date.now() / 1000) - 1 }, { expiresIn: "7d" });
    const res = await app.inject({ method: "POST", url: "/v1/auth/logout-all", headers: { authorization: `Bearer ${token}` } });
    expect(res.statusCode).toBe(200);
    const after = await app.inject({ method: "POST", url: "/v1/auth/logout-all", headers: { authorization: `Bearer ${token}` } });
    expect(after.statusCode).toBe(401);
    await app.close();
  });

  it("a token minted in the revocation second is dead (#117)", async () => {
    // Freeze the clock so the login and the revocation fall in the same wall-clock second. Under
    // the old `iat < epoch` comparison the token survived; this is the regression test.
    vi.useFakeTimers({ toFake: ["Date"] });
    vi.setSystemTime(new Date("2026-10-18T12:00:00.400Z"));
    const app = await buildApp(authRoutes, "/v1/auth");
    const login = await app.inject({ method: "POST", url: "/v1/auth/login", payload: { email: "a@b.co", password: PASSWORD } });
    const token = login.json().token as string;

    const kill = await app.inject({ method: "POST", url: "/v1/auth/logout-all", headers: { authorization: `Bearer ${token}` } });
    expect(kill.statusCode).toBe(200);

    // The security assertion: minted at T, revoked at T, refused. On `main` this returned 200.
    const after = await app.inject({ method: "POST", url: "/v1/auth/logout-all", headers: { authorization: `Bearer ${token}` } });
    expect(after.statusCode).toBe(401);
    expect(after.json().error).toBe("session_revoked");

    expect(store.get("auth:session-version:p1")).toBe("1");
    const claims = app.jwt.decode(token) as { iat: number; sv: number };
    expect(claims.iat).toBe(Math.floor(Date.now() / 1000));
    expect(claims.sv).toBe(0);
    await app.close();
  });

  it("a token minted one second before the revocation is refused while one minted after works (#117)", async () => {
    vi.useFakeTimers({ toFake: ["Date"] });
    const T = Math.floor(Date.parse("2026-10-18T12:00:00.400Z") / 1000);
    const app = await buildApp(authRoutes, "/v1/auth");

    // One second before the revocation.
    vi.setSystemTime(new Date((T - 1) * 1000 + 400));
    const older = (await app.inject({ method: "POST", url: "/v1/auth/login", payload: { email: "a@b.co", password: PASSWORD } })).json().token as string;

    // Revoke at T.
    vi.setSystemTime(new Date(T * 1000 + 400));
    expect((await app.inject({ method: "POST", url: "/v1/auth/logout-all", headers: { authorization: `Bearer ${older}` } })).statusCode).toBe(200);

    // One second after it.
    vi.setSystemTime(new Date((T + 1) * 1000 + 400));
    const newer = (await app.inject({ method: "POST", url: "/v1/auth/login", payload: { email: "a@b.co", password: PASSWORD } })).json().token as string;

    // The pre-revocation token is refused; the post-revocation one works.
    expect((await app.inject({ method: "POST", url: "/v1/auth/logout-all", headers: { authorization: `Bearer ${older}` } })).statusCode).toBe(401);
    expect((await app.inject({ method: "POST", url: "/v1/auth/logout-all", headers: { authorization: `Bearer ${newer}` } })).statusCode).toBe(200);

    expect((app.jwt.decode(older) as { iat: number; sv: number })).toMatchObject({ iat: T - 1, sv: 0 });
    expect((app.jwt.decode(newer) as { iat: number; sv: number })).toMatchObject({ iat: T + 1, sv: 1 });
    await app.close();
  });

  it("a pre-#117 token without `sv`, minted in the revocation second, is refused too (#117)", async () => {
    vi.useFakeTimers({ toFake: ["Date"] });
    vi.setSystemTime(new Date("2026-10-18T12:00:00.400Z"));
    const app = await buildApp(authRoutes, "/v1/auth");
    // Exactly what `main` minted before this change: no sessions-version claim.
    const legacy = app.jwt.sign(
      { sub: "p1", familyId: "fam-1", role: "parent", jti: "cccccccccccccccccccccccccccccccc", iat: Math.floor(Date.now() / 1000) },
      { expiresIn: "7d" },
    );
    expect((await app.inject({ method: "POST", url: "/v1/auth/logout-all", headers: { authorization: `Bearer ${legacy}` } })).statusCode).toBe(200);
    const after = await app.inject({ method: "POST", url: "/v1/auth/logout-all", headers: { authorization: `Bearer ${legacy}` } });
    expect(after.statusCode).toBe(401);
    expect(after.json().error).toBe("session_revoked");
    await app.close();
  });

  it("single logout with the refresh token also revokes the access token issued with it", async () => {
    const app = await buildApp(authRoutes, "/v1/auth");
    const login = await app.inject({ method: "POST", url: "/v1/auth/login", payload: { email: "a@b.co", password: PASSWORD } });
    const { token, refreshToken } = login.json();
    const { jti } = app.jwt.decode(token) as { jti: string };
    expect((await app.inject({ method: "POST", url: "/v1/auth/logout-all", headers: { authorization: `Bearer ${token}` } })).statusCode).toBe(200);
    // (logout-all above bumped the sessions version and the legacy epoch; clear both to isolate
    // the jti path from the parent-wide revocation)
    store.delete("auth:invalid-before:p1");
    store.delete("auth:session-version:p1");
    const out = await app.inject({ method: "POST", url: "/v1/auth/logout", payload: { refreshToken } });
    expect(out.statusCode).toBe(200);
    expect(store.get(`revoked:token:${jti}`)).toBe("1");
    const dead = await app.inject({ method: "POST", url: "/v1/auth/logout-all", headers: { authorization: `Bearer ${token}` } });
    expect(dead.statusCode).toBe(401);
    await app.close();
  });

  it("a purpose-scoped token is not a bearer credential on requireFamily routes either (#146)", async () => {
    const app = await buildApp(rulesRoutes, "/v1/rules");
    prismaMock.child.findUnique.mockResolvedValue({ id: "child-1", familyId: "fam-1" });
    prismaMock.ruleSet.findUnique.mockResolvedValue({ childId: "child-1", appRules: [], routines: [] });

    // A reset token carrying a family and role claim must still stop at the shared guard, before
    // the resource is loaded.
    const purposeToken = app.jwt.sign({ sub: "p1", familyId: "fam-1", role: "parent", purpose: "password_reset" });
    const refused = await app.inject({
      method: "GET",
      url: "/v1/rules/child-1",
      headers: { authorization: `Bearer ${purposeToken}` },
    });
    expect(refused.statusCode).toBe(401);
    expect(refused.json().error).toBe("unauthorized");
    expect(prismaMock.child.findUnique).not.toHaveBeenCalled();

    // A live session token still reads the child.
    const allowed = await app.inject({ method: "GET", url: "/v1/rules/child-1", headers: authHeader(app, "fam-1", "p1") });
    expect(allowed.statusCode).toBe(200);
    await app.close();
  });

  it("#158: a revocation that lands during /token/refresh leaves neither returned credential live", async () => {
    const app = await buildApp(authRoutes, "/v1/auth");
    const login = await app.inject({ method: "POST", url: "/v1/auth/login", payload: { email: "a@b.co", password: PASSWORD } });
    expect(login.statusCode).toBe(200);
    const { refreshToken } = login.json();

    // Park the DB round trip that `/token/refresh` performs after it has accepted the refresh token
    // and before it mints: the exact window a concurrent revocation used to slip through.
    let releaseDb!: () => void;
    const dbGate = new Promise<void>((resolve) => { releaseDb = resolve; });
    let dbReached!: () => void;
    const dbParked = new Promise<void>((resolve) => { dbReached = resolve; });
    prismaMock.parent.findUnique.mockImplementationOnce(async () => {
      dbReached();
      await dbGate;
      return OWNER;
    });

    const refreshing = app.inject({ method: "POST", url: "/v1/auth/token/refresh", payload: { refreshToken } });
    await dbParked;
    // Revoke every session while the refresh is in flight.
    await invalidateSessionsBefore("p1");
    releaseDb();
    const rotated = await refreshing;
    expect(rotated.statusCode).toBe(200);

    const accessToken = rotated.json().token as string;
    const nextRefresh = rotated.json().refreshToken as string;
    expect(accessToken).toBeTruthy();
    expect(nextRefresh).toBeTruthy();

    // The access token carries the version read before the revocation, so it is born stale.
    const claims = app.jwt.decode(accessToken) as { sub: string; jti: string; iat: number; sv: number };
    expect(claims.sv).toBe(0);
    expect(await isParentSessionLive(claims)).toBe(false);
    const dead = await app.inject({ method: "POST", url: "/v1/auth/logout-all", headers: { authorization: `Bearer ${accessToken}` } });
    expect(dead.statusCode).toBe(401);
    expect(dead.json().error).toBe("session_revoked");

    // The refresh token issued alongside carries the same stale version: it cannot resurrect the
    // session by minting a new, current access token later.
    const reuse = await app.inject({ method: "POST", url: "/v1/auth/token/refresh", payload: { refreshToken: nextRefresh } });
    expect(reuse.statusCode).toBe(401);
    expect(reuse.json().error).toBe("session_revoked");
    await app.close();
  });

  it("#158: a Redis failure during revocation fails the request (5xx), it does not report success", async () => {
    const app = await buildApp(authRoutes, "/v1/auth");
    const login = await app.inject({ method: "POST", url: "/v1/auth/login", payload: { email: "a@b.co", password: PASSWORD } });
    expect(login.statusCode).toBe(200);
    const { token } = login.json();

    const redis = getRedis() as unknown as MockRedis;
    redis.incrby.mockRejectedValue(new Error("redis unavailable"));

    // `invalidateSessionsBefore` no longer swallows the counter bump: the caller must see a failure
    // so the client retries instead of believing every token was revoked.
    await expect(invalidateSessionsBefore("p1")).rejects.toThrow("redis unavailable");
    const killed = await app.inject({ method: "POST", url: "/v1/auth/logout-all", headers: { authorization: `Bearer ${token}` } });
    expect(killed.statusCode).toBe(500);
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

  it("requireFamily scopes by the CURRENT Parent.familyId, not the token claim (family move / revoked session)", async () => {
    const app = await buildApp(rulesRoutes, "/v1/rules");
    // p1 moved fam-1 -> fam-2, but holds an access token minted while still in fam-1.
    prismaMock.parent.findUnique.mockResolvedValue({ id: "p1", familyId: "fam-2", role: "owner", permissions: [] });
    prismaMock.child.findUnique.mockResolvedValue({ id: "child-1", familyId: "fam-1" });
    prismaMock.ruleSet.findUnique.mockResolvedValue({ childId: "child-1", appRules: [], routines: [] });
    const oldScope = await app.inject({ method: "GET", url: "/v1/rules/child-1", headers: authHeader(app, "fam-1", "p1") });
    expect(oldScope.statusCode).toBe(403);
    expect(prismaMock.ruleSet.findUnique).not.toHaveBeenCalled();

    // A token minted after the move reaches the new family's child.
    prismaMock.child.findUnique.mockResolvedValue({ id: "child-2", familyId: "fam-2" });
    prismaMock.ruleSet.findUnique.mockResolvedValue({ childId: "child-2", appRules: [], routines: [] });
    const current = await app.inject({ method: "GET", url: "/v1/rules/child-2", headers: authHeader(app, "fam-2", "p1") });
    expect(current.statusCode).toBe(200);

    // The sessions-invalid-before epoch is enforced on family-scoped routes too (this route has no
    // requireParent in front of it): a token issued before the bump is dead here as well.
    const store = wireRedisStore();
    const now = Math.floor(Date.now() / 1000);
    store.set("auth:invalid-before:p1", String(now));
    const revokedToken = app.jwt.sign(
      { sub: "p1", familyId: "fam-2", role: "parent", jti: "dddddddddddddddddddddddddddddddd", iat: now - 5 },
      { expiresIn: "7d" },
    );
    const revoked = await app.inject({ method: "GET", url: "/v1/rules/child-2", headers: { authorization: `Bearer ${revokedToken}` } });
    expect(revoked.statusCode).toBe(401);
    expect(revoked.json().error).toBe("session_revoked");
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

  // Plan 2.7 F3 (Claude, #329, 2026-10-23): birthYear sets the age risk scoring uses, so editing a
  // child's profile is a rules decision. Before the fix the guardian below got 200 and changed it.
  it("a guardian without the 'rules' permission cannot edit a child's profile (403 permission_required); with it 200", async () => {
    const app = await buildApp(familyRoutes, "/v1/family");
    prismaMock.child.findUnique.mockResolvedValue({ id: "child-1", familyId: "fam-1" });
    prismaMock.child.update.mockResolvedValue({ id: "child-1", birthYear: 2008 });
    const h = authHeader(app, "fam-1", "p-g");

    prismaMock.parent.findUnique.mockResolvedValue({ id: "p-g", familyId: "fam-1", role: "guardian", permissions: ["alerts"] });
    const refused = await app.inject({ method: "PATCH", url: "/v1/family/children/child-1", headers: h, payload: { birthYear: 2008 } });
    expect(refused.statusCode).toBe(403);
    expect(refused.json()).toEqual({ error: "permission_required", permission: "rules" });
    expect(prismaMock.child.update).not.toHaveBeenCalled();

    prismaMock.parent.findUnique.mockResolvedValue({ id: "p-g", familyId: "fam-1", role: "guardian", permissions: ["rules"] });
    const allowed = await app.inject({ method: "PATCH", url: "/v1/family/children/child-1", headers: h, payload: { birthYear: 2008 } });
    expect(allowed.statusCode).toBe(200);
    expect(prismaMock.child.update).toHaveBeenCalledTimes(1);
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
