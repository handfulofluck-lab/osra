import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import Fastify from "fastify";
import fastifyJwt from "@fastify/jwt";
import argon2 from "argon2";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { familyRoutes } from "../src/routes/family.js";
import { meRoutes } from "../src/routes/me.js";
import { getRedis } from "../src/redis.js";
import {
  FAMILY_SCOPED_DELETES,
  KEPT_ON_DELETION,
  KEPT_ON_PARENT_DELETION,
  PARENT_SCOPED_DELETES,
} from "../src/lib/accountDeletion.js";
import { verifyTotpFresh } from "../src/lib/mfaVerify.js";
import { AUTH_RATE_LIMIT } from "../src/lib/rateLimits.js";
import { invalidateSessionsBefore, isParentSessionLive, sessionVersionKey, signParentToken } from "../src/lib/sessions.js";
import { CHILD_SCOPED_DELETE_ORDER } from "../src/lib/usageModel.js";
import { MockRedis, buildApp, prismaMock, resetPrismaMock } from "./helpers.js";

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
vi.mock("../src/lib/mfaVerify.js", () => ({ verifyTotpFresh: vi.fn(async () => false) }));

/**
 * #442 PR 1: account deletion, the server half (design: #442 comment 6495864112).
 *
 * Each test names its mutant: the one-line change to the production code that makes it fail.
 */

const OWNER = {
  id: "parent-1", familyId: "fam-1", email: "owner@example.com", displayName: "Owner",
  role: "owner", permissions: [] as string[], passwordHash: "h", mfaEnabled: false, mfaSecret: null, sessionVersion: 3,
};
const CO = { ...OWNER, id: "parent-2", email: "co@example.com", displayName: "Co", role: "co-parent" };
const BODY = { password: "CorrectHorseBatteryStaple!" };

/** A Map-backed Redis for the keys these tests read back. */
function wireRedisStore(): Map<string, string> {
  const store = new Map<string, string>();
  const redis = getRedis() as unknown as MockRedis;
  redis.get.mockImplementation(async (key: string) => store.get(key) ?? null);
  redis.set.mockImplementation(async (key: string, value: string, ...args: unknown[]) => {
    if (args.includes("NX") && store.has(key)) return null;
    store.set(key, String(value));
    return "OK";
  });
  redis.del.mockImplementation(async (...keys: string[]) => keys.reduce((n, k) => n + (store.delete(k) ? 1 : 0), 0));
  redis.incrby.mockImplementation(async (key: string, by: number) => {
    const next = Number(store.get(key) ?? 0) + by;
    store.set(key, String(next));
    return next;
  });
  redis.smembers.mockResolvedValue([]);
  redis.publish.mockResolvedValue(0);
  return store;
}

/** The family's rows as the routes read them: two parents, two children, no devices. */
function seedFamily(caller = OWNER) {
  prismaMock.parent.findUnique.mockImplementation(async ({ where }: { where: { id?: string } }) =>
    where.id === OWNER.id ? OWNER : where.id === CO.id ? CO : where.id === caller.id ? caller : null,
  );
  prismaMock.parent.findMany.mockResolvedValue([{ id: OWNER.id }, { id: CO.id }]);
  prismaMock.parent.update.mockResolvedValue({});
  prismaMock.child.findMany.mockResolvedValue([{ id: "child-1" }, { id: "child-2" }]);
  prismaMock.child.delete.mockResolvedValue({});
  prismaMock.family.delete.mockResolvedValue({});
  prismaMock.consentRecord.count.mockResolvedValue(0);
  for (const model of new Set([...CHILD_SCOPED_DELETE_ORDER, ...Object.keys(FAMILY_SCOPED_DELETES)])) {
    if (model !== "child") (prismaMock as unknown as Record<string, Record<string, ReturnType<typeof vi.fn>>>)[model].deleteMany.mockResolvedValue({ count: 1 });
  }
}

const tokenFor = (app: { jwt: { sign: (c: object) => string } }, p: { id: string; familyId: string }, sv: number) =>
  ({ authorization: `Bearer ${app.jwt.sign({ sub: p.id, familyId: p.familyId, role: "parent", sv, jti: `jti-${p.id}-${sv}` })}` });

async function appWith(routes: typeof familyRoutes, prefix: string) {
  return buildApp(routes, prefix, { sessionGuard: true });
}

beforeEach(() => {
  resetPrismaMock();
  vi.mocked(argon2.verify).mockResolvedValue(true);
  vi.mocked(verifyTotpFresh).mockResolvedValue(false);
});

describe("DELETE /v1/family — the owner deletes the whole family", () => {
  it("D1 deletes every child, every family row, every parent and the family, revoking first", async () => {
    const store = wireRedisStore();
    store.set(sessionVersionKey(OWNER.id), "3");
    store.set(sessionVersionKey(CO.id), "3");
    seedFamily();
    const app = await appWith(familyRoutes, "/v1/family");
    const res = await app.inject({ method: "DELETE", url: "/v1/family", headers: tokenFor(app, OWNER, 3), payload: BODY });

    expect(res.statusCode).toBe(200);
    expect(res.json()).toMatchObject({ deleted: "family", familyId: "fam-1", children: 2, parents: 2 });
    // Every child through the ADR-0013 cascade.
    expect(prismaMock.child.delete).toHaveBeenCalledWith({ where: { id: "child-1" } });
    expect(prismaMock.child.delete).toHaveBeenCalledWith({ where: { id: "child-2" } });
    // Every family-scoped and parent-scoped table, by name. Mutant: drop an entry from FAMILY_SCOPED_DELETES.
    const parentIds = { in: [OWNER.id, CO.id] };
    expect(prismaMock.familyInvite.deleteMany).toHaveBeenCalledWith({ where: { familyId: "fam-1" } });
    expect(prismaMock.digestRecipient.deleteMany).toHaveBeenCalledWith({ where: { familyId: "fam-1" } });
    expect(prismaMock.digestSend.deleteMany).toHaveBeenCalledWith({ where: { familyId: "fam-1" } });
    expect(prismaMock.digestPrefs.deleteMany).toHaveBeenCalledWith({ where: { familyId: "fam-1" } });
    expect(prismaMock.mfaResetRequest.deleteMany).toHaveBeenCalledWith({ where: { parentId: parentIds } });
    expect(prismaMock.parentPushToken.deleteMany).toHaveBeenCalledWith({ where: { parentId: parentIds } });
    expect(prismaMock.parentMfaRecoveryCode.deleteMany).toHaveBeenCalledWith({ where: { parentId: parentIds } });
    expect(prismaMock.parent.deleteMany).toHaveBeenCalledWith({ where: { familyId: "fam-1" } });
    expect(prismaMock.family.delete).toHaveBeenCalledWith({ where: { id: "fam-1" } });
    // Revoked before anything is deleted. Mutant: move the bump after the transaction.
    const bump = prismaMock.parent.update.mock.invocationCallOrder[0];
    expect(prismaMock.parent.update).toHaveBeenCalledTimes(2);
    expect(bump).toBeLessThan(prismaMock.child.delete.mock.invocationCallOrder[0]);
    // And tombstoned afterwards, both parents. Mutant: drop the tombstoneParentSessions loop.
    expect(store.get(sessionVersionKey(OWNER.id))).toBe("deleted");
    expect(store.get(sessionVersionKey(CO.id))).toBe("deleted");
  });

  it("D2 a co-parent or guardian gets 403 owner_only and nothing is touched", async () => {
    // Mutant: drop the `role !== "owner"` check, and the co-parent deletes the family.
    wireRedisStore();
    seedFamily(CO);
    const app = await appWith(familyRoutes, "/v1/family");
    for (const role of ["co-parent", "guardian"]) {
      prismaMock.parent.findUnique.mockResolvedValue({ ...CO, role });
      const res = await app.inject({ method: "DELETE", url: "/v1/family", headers: tokenFor(app, CO, 3), payload: BODY });
      expect(res.statusCode).toBe(403);
      expect(res.json()).toEqual({ error: "owner_only" });
    }
    expect(prismaMock.family.delete).not.toHaveBeenCalled();
    expect(prismaMock.parent.update).not.toHaveBeenCalled();
  });

  it("D3 the body is required, and a wrong password is 401 reauth_failed with nothing touched", async () => {
    wireRedisStore();
    seedFamily();
    const app = await appWith(familyRoutes, "/v1/family");
    const noBody = await app.inject({ method: "DELETE", url: "/v1/family", headers: tokenFor(app, OWNER, 3) });
    expect(noBody.statusCode).toBe(400);

    // Mutant: skip checkReauth, and a stolen session alone deletes the family.
    vi.mocked(argon2.verify).mockResolvedValue(false);
    const wrong = await app.inject({ method: "DELETE", url: "/v1/family", headers: tokenFor(app, OWNER, 3), payload: BODY });
    expect(wrong.statusCode).toBe(401);
    expect(wrong.json()).toEqual({ error: "reauth_failed" });
    expect(prismaMock.family.delete).not.toHaveBeenCalled();
    expect(prismaMock.parent.update).not.toHaveBeenCalled();
  });

  it("D4 with MFA on, the password alone is not enough; a fresh code is", async () => {
    wireRedisStore();
    seedFamily();
    const mfaOwner = { ...OWNER, mfaEnabled: true, mfaSecret: "enc:secret" };
    const app = await appWith(familyRoutes, "/v1/family");
    prismaMock.parent.findUnique.mockResolvedValue(mfaOwner);

    // Mutant: return null from checkReauth when the password matches, whatever mfaEnabled says.
    const noCode = await app.inject({ method: "DELETE", url: "/v1/family", headers: tokenFor(app, OWNER, 3), payload: BODY });
    expect(noCode.json()).toEqual({ error: "reauth_failed" });
    const badCode = await app.inject({ method: "DELETE", url: "/v1/family", headers: tokenFor(app, OWNER, 3), payload: { ...BODY, mfaCode: "000000" } });
    expect(badCode.json()).toEqual({ error: "reauth_failed" });
    expect(prismaMock.family.delete).not.toHaveBeenCalled();

    // The policy is on but no factor is bound (#183): no code can be asked for, so no deletion either.
    prismaMock.parent.findUnique.mockResolvedValue({ ...mfaOwner, mfaSecret: null });
    const unbound = await app.inject({ method: "DELETE", url: "/v1/family", headers: tokenFor(app, OWNER, 3), payload: { ...BODY, mfaCode: "123456" } });
    expect(unbound.json()).toEqual({ error: "mfa_reenroll_required" });

    prismaMock.parent.findUnique.mockResolvedValue(mfaOwner);
    vi.mocked(verifyTotpFresh).mockResolvedValue(true);
    const ok = await app.inject({ method: "DELETE", url: "/v1/family", headers: tokenFor(app, OWNER, 3), payload: { ...BODY, mfaCode: "123456" } });
    expect(ok.statusCode).toBe(200);
    expect(verifyTotpFresh).toHaveBeenCalledWith(OWNER.id, "enc:secret", "123456");
  });

  it("D5 a parent holding a consent record for a child elsewhere refuses the deletion (409)", async () => {
    wireRedisStore();
    seedFamily();
    prismaMock.consentRecord.count.mockResolvedValue(1);
    const app = await appWith(familyRoutes, "/v1/family");
    const res = await app.inject({ method: "DELETE", url: "/v1/family", headers: tokenFor(app, OWNER, 3), payload: BODY });
    expect(res.statusCode).toBe(409);
    expect(res.json()).toEqual({ error: "consent_records_held" });
    expect(prismaMock.consentRecord.count).toHaveBeenCalledWith({
      where: { parentId: { in: [OWNER.id, CO.id] }, child: { familyId: { not: "fam-1" } } },
    });
    expect(prismaMock.child.delete).not.toHaveBeenCalled();
  });
});

describe("DELETE /v1/me — a co-parent or guardian deletes only themselves", () => {
  it("M1 deletes that parent's own rows and nothing of the family", async () => {
    const store = wireRedisStore();
    store.set(sessionVersionKey(CO.id), "3");
    seedFamily(CO);
    prismaMock.parentPushToken.deleteMany.mockResolvedValue({ count: 2 });
    for (const m of ["mfaResetRequest", "parentMfaRecoveryCode", "familyInvite", "parent"]) {
      (prismaMock as unknown as Record<string, Record<string, ReturnType<typeof vi.fn>>>)[m].deleteMany.mockResolvedValue({ count: 1 });
    }
    const app = await appWith(meRoutes, "/v1/me");
    const res = await app.inject({ method: "DELETE", url: "/v1/me", headers: tokenFor(app, CO, 3), payload: BODY });

    expect(res.statusCode).toBe(200);
    expect(res.json()).toMatchObject({ deleted: "parent", parentId: CO.id, rows: { parentPushToken: 2, parent: 1 } });
    expect(prismaMock.parent.deleteMany).toHaveBeenCalledWith({ where: { id: CO.id } });
    expect(prismaMock.parentPushToken.deleteMany).toHaveBeenCalledWith({ where: { parentId: CO.id } });
    expect(prismaMock.parentMfaRecoveryCode.deleteMany).toHaveBeenCalledWith({ where: { parentId: CO.id } });
    expect(prismaMock.mfaResetRequest.deleteMany).toHaveBeenCalledWith({ where: { parentId: CO.id } });
    expect(prismaMock.familyInvite.deleteMany).toHaveBeenCalledWith({ where: { familyId: "fam-1", email: CO.email } });
    // The family, the children and the other parent stay.
    expect(prismaMock.family.delete).not.toHaveBeenCalled();
    expect(prismaMock.child.delete).not.toHaveBeenCalled();
    expect(store.get(sessionVersionKey(CO.id))).toBe("deleted");
    expect(store.has(sessionVersionKey(OWNER.id))).toBe(false);
  });

  it("M2 the owner gets 409 owner_must_delete_family", async () => {
    // Mutant: drop the owner check, and the family is left with no owner.
    wireRedisStore();
    seedFamily();
    const app = await appWith(meRoutes, "/v1/me");
    const res = await app.inject({ method: "DELETE", url: "/v1/me", headers: tokenFor(app, OWNER, 3), payload: BODY });
    expect(res.statusCode).toBe(409);
    expect(res.json()).toEqual({ error: "owner_must_delete_family" });
    expect(prismaMock.parent.deleteMany).not.toHaveBeenCalled();
  });

  it("M3 a wrong password is 401 reauth_failed", async () => {
    wireRedisStore();
    seedFamily(CO);
    vi.mocked(argon2.verify).mockResolvedValue(false);
    const app = await appWith(meRoutes, "/v1/me");
    const res = await app.inject({ method: "DELETE", url: "/v1/me", headers: tokenFor(app, CO, 3), payload: BODY });
    expect(res.statusCode).toBe(401);
    expect(res.json()).toEqual({ error: "reauth_failed" });
    expect(prismaMock.parent.deleteMany).not.toHaveBeenCalled();
  });
});

describe("§3 a deleted parent's token never works again", () => {
  it("T1 with Redis intact, the tombstone refuses a token at any version", async () => {
    const store = wireRedisStore();
    store.set(sessionVersionKey(OWNER.id), "deleted");
    // Mutant: parseVersion ignores the marker (reads it as 0), and an `sv=0` token is live.
    expect(await isParentSessionLive({ sub: OWNER.id, sv: 0 })).toBe(false);
    expect(await isParentSessionLive({ sub: OWNER.id, sv: 999 })).toBe(false);
  });

  it("T2 after a Redis flush, no Parent row means deleted, not version 0", async () => {
    // The defect: `loadSessionState` read a missing row as version 0, so a token minted at sv=0
    // stayed valid for its whole 7 days after the account was gone.
    // Mutant: drop the `if (!row)` branch of loadSessionState.
    const store = wireRedisStore();
    prismaMock.parent.findUnique.mockResolvedValue(null);
    const app = await appWith(familyRoutes, "/v1/family");
    const res = await app.inject({ method: "GET", url: "/v1/family/me", headers: tokenFor(app, OWNER, 0) });
    expect(res.statusCode).toBe(401);
    expect(res.json()).toEqual({ error: "session_revoked" });
    // The cold read wrote the tombstone, so the next request does not need the database.
    expect(store.get(sessionVersionKey(OWNER.id))).toBe("deleted");
  });

  it("T3 the full sequence: delete, flush Redis, the old token is refused", async () => {
    const store = wireRedisStore();
    store.set(sessionVersionKey(OWNER.id), "3");
    seedFamily();
    const app = await appWith(familyRoutes, "/v1/family");
    const old = tokenFor(app, OWNER, 3);
    expect((await app.inject({ method: "DELETE", url: "/v1/family", headers: old, payload: BODY })).statusCode).toBe(200);

    store.clear();
    prismaMock.parent.findUnique.mockResolvedValue(null);
    const after = await app.inject({ method: "GET", url: "/v1/family/me", headers: old });
    expect(after.statusCode).toBe(401);
    expect(after.json()).toEqual({ error: "session_revoked" });
  });

  it("T4 nothing mints a token for a tombstoned parent, and a later revocation is a no-op", async () => {
    const store = wireRedisStore();
    store.set(sessionVersionKey(OWNER.id), "deleted");
    const app = Fastify({ logger: false });
    await app.register(fastifyJwt, { secret: "test-secret" });
    await app.ready();
    await expect(signParentToken(app, OWNER)).rejects.toThrow(/parent_deleted/);
    // The refresh-reuse theft response can still name a deleted parent; it must not try to update a row.
    await invalidateSessionsBefore(OWNER.id);
    expect(prismaMock.parent.update).not.toHaveBeenCalled();
    expect(store.get(sessionVersionKey(OWNER.id))).toBe("deleted");
  });
});

describe("§2 both routes are behind the auth routes' rate limit", () => {
  it("R1 DELETE /v1/family and DELETE /v1/me carry AUTH_RATE_LIMIT", async () => {
    // Mutant: drop `config: { rateLimit: AUTH_RATE_LIMIT }` from either route.
    const seen = new Map<string, unknown>();
    const app = Fastify({ logger: false });
    await app.register(fastifyJwt, { secret: "test-secret" });
    app.addHook("onRoute", (route) => {
      if (route.method === "DELETE") seen.set(route.url, (route.config as { rateLimit?: unknown } | undefined)?.rateLimit);
    });
    await app.register(familyRoutes, { prefix: "/v1/family" });
    await app.register(meRoutes, { prefix: "/v1/me" });
    await app.ready();
    // Fastify registers the prefix root both with and without the trailing slash; each must carry it.
    const of = (re: RegExp) => [...seen].filter(([url]) => re.test(url)).map(([, rl]) => rl);
    expect(of(/^\/v1\/family\/?$/).length).toBeGreaterThan(0);
    expect(of(/^\/v1\/me\/?$/).length).toBeGreaterThan(0);
    for (const rl of [...of(/^\/v1\/family\/?$/), ...of(/^\/v1\/me\/?$/)]) expect(rl).toBe(AUTH_RATE_LIMIT);
  });
});

describe("§4 coverage guard: no table escapes the deletion by being forgotten", () => {
  const schema = readFileSync(fileURLToPath(new URL("../prisma/schema.prisma", import.meta.url)), "utf8");
  /** model name (as the client spells it, first letter lower-case) -> its scalar field names. */
  const models = new Map<string, Set<string>>();
  for (const m of schema.matchAll(/^model (\w+) \{([\s\S]*?)^\}/gm)) {
    const fields = new Set([...m[2].matchAll(/^\s+(\w+)\s+\w/gm)].map((f) => f[1]));
    models.set(m[1][0].toLowerCase() + m[1].slice(1), fields);
  }
  const scoped = [...models].filter(([, f]) => f.has("familyId") || f.has("parentId") || f.has("childId")).map(([n]) => n);

  it("G1 every model with a familyId, parentId or childId is erased or kept with a reason", () => {
    // Mutant: remove `digestRecipient` from FAMILY_SCOPED_DELETES, and this row names it.
    expect(scoped.length).toBeGreaterThan(15); // the parse found the schema, not an empty file
    const decided = new Set<string>([...CHILD_SCOPED_DELETE_ORDER, ...Object.keys(FAMILY_SCOPED_DELETES), ...Object.keys(KEPT_ON_DELETION)]);
    expect(scoped.filter((name) => !decided.has(name))).toEqual([]);
  });

  it("G2 every model with a parentId is in DELETE /v1/me's list or kept with a reason", () => {
    const decided = new Set([...Object.keys(PARENT_SCOPED_DELETES), ...Object.keys(KEPT_ON_PARENT_DELETION)]);
    const withParent = [...models].filter(([, f]) => f.has("parentId")).map(([n]) => n);
    expect(withParent.filter((name) => !decided.has(name))).toEqual([]);
  });

  it("G3 every name in the lists is a real model, so a typo cannot pass the guard", () => {
    const named = [...CHILD_SCOPED_DELETE_ORDER, ...Object.keys(FAMILY_SCOPED_DELETES), ...Object.keys(PARENT_SCOPED_DELETES),
      ...Object.keys(KEPT_ON_DELETION), ...Object.keys(KEPT_ON_PARENT_DELETION)];
    expect(named.filter((name) => !models.has(name))).toEqual([]);
    for (const reason of [...Object.values(KEPT_ON_DELETION), ...Object.values(KEPT_ON_PARENT_DELETION)]) {
      expect(reason.length).toBeGreaterThan(20);
    }
  });
});
