import { beforeEach, describe, expect, it, vi } from "vitest";
import { inviteRoutes } from "../src/routes/invites.js";
import { getRedis } from "../src/redis.js";
import { setEmailSender } from "../src/lib/email/index.js";
import { MockRedis, authHeader, buildApp, prismaMock, resetPrismaMock } from "./helpers.js";

vi.mock("../src/db.js", async () => {
  const { prismaMock } = await import("./helpers.js");
  return { prisma: prismaMock };
});
vi.mock("ioredis", async () => {
  const { MockRedis } = await import("./helpers.js");
  return { Redis: MockRedis };
});

const OWNER = { id: "parent-1", familyId: "fam-1", email: "dad@example.com", role: "owner", permissions: [] };
const INVITE_ROW = {
  id: "inv-1",
  familyId: "fam-1",
  email: "mom@example.com",
  role: "co-parent",
  permissions: ["location", "controls"],
  status: "pending",
  createdAt: "2026-09-16T00:00:00.000Z",
};

/** In-memory Redis state so invite tokens round-trip like a real store. */
const store = new Map<string, string>();
let lastSetArgs: unknown[] = [];

function wireRedis(): MockRedis {
  const redis = getRedis() as unknown as MockRedis;
  redis.get.mockImplementation(async (key: string) => store.get(key) ?? null);
  redis.set.mockImplementation(async (key: string, value: unknown, ...rest: unknown[]) => {
    store.set(key, String(value));
    lastSetArgs = [key, value, ...rest];
    return "OK";
  });
  redis.publish.mockResolvedValue(1);
  redis.lpush.mockResolvedValue(1);
  redis.ltrim.mockResolvedValue("OK");
  return redis;
}

describe("family invites (Feature #13)", () => {
  beforeEach(() => {
    resetPrismaMock();
    store.clear();
    lastSetArgs = [];
    wireRedis();
  });

  it("owner creates an invite (201), stores a 7-day accept token in Redis", async () => {
    const app = await buildApp(inviteRoutes, "/v1/family");
    prismaMock.parent.findUnique.mockResolvedValue(OWNER);
    prismaMock.familyInvite.create.mockResolvedValue(INVITE_ROW);

    const res = await app.inject({
      method: "POST",
      url: "/v1/family/invites",
      headers: authHeader(app),
      payload: { email: "Mom@Example.com", role: "co-parent", permissions: ["location", "controls"] },
    });
    expect(res.statusCode).toBe(201);
    expect(res.json().acceptToken).toBe("inv-1");
    expect(res.json().invite.status).toBe("pending");
    expect(prismaMock.familyInvite.create).toHaveBeenCalledWith({
      data: {
        familyId: "fam-1",
        email: "mom@example.com", // normalized to lowercase
        role: "co-parent",
        permissions: ["location", "controls"],
        status: "pending",
      },
    });
    // Token payload + 7-day TTL in Redis.
    expect(lastSetArgs[0]).toBe("invite:inv-1");
    expect(JSON.parse(lastSetArgs[1] as string)).toEqual({
      familyId: "fam-1",
      email: "mom@example.com",
      role: "co-parent",
      permissions: ["location", "controls"],
    });
    expect(lastSetArgs[2]).toBe("EX");
    expect(lastSetArgs[3]).toBe(7 * 24 * 60 * 60);
    await app.close();
  });

  it("rejects invite creation from a non-owner parent (403)", async () => {
    const app = await buildApp(inviteRoutes, "/v1/family");
    prismaMock.parent.findUnique.mockResolvedValue({ ...OWNER, role: "co-parent" });

    const res = await app.inject({
      method: "POST",
      url: "/v1/family/invites",
      headers: authHeader(app),
      payload: { email: "mom@example.com", role: "co-parent", permissions: [] },
    });
    expect(res.statusCode).toBe(403);
    expect(res.json().error).toBe("owner_role_required");
    expect(prismaMock.familyInvite.create).not.toHaveBeenCalled();
    await app.close();
  });

  it("rejects malformed invite bodies with 400", async () => {
    const app = await buildApp(inviteRoutes, "/v1/family");
    prismaMock.parent.findUnique.mockResolvedValue(OWNER);

    for (const payload of [
      { email: "not-an-email", role: "co-parent", permissions: [] },
      { email: "mom@example.com", role: "admin", permissions: [] },
      { role: "co-parent", permissions: [] },
    ]) {
      const res = await app.inject({
        method: "POST",
        url: "/v1/family/invites",
        headers: authHeader(app),
        payload: payload as Record<string, unknown>,
      });
      expect(res.statusCode).toBe(400);
    }
    expect(prismaMock.familyInvite.create).not.toHaveBeenCalled();
    await app.close();
  });

  it("lists the family's invites (200)", async () => {
    const app = await buildApp(inviteRoutes, "/v1/family");
    prismaMock.familyInvite.findMany.mockResolvedValue([INVITE_ROW]);

    const res = await app.inject({ method: "GET", url: "/v1/family/invites", headers: authHeader(app) });
    expect(res.statusCode).toBe(200);
    expect(res.json().invites).toHaveLength(1);
    expect(prismaMock.familyInvite.findMany).toHaveBeenCalledWith({
      where: { familyId: "fam-1" },
      orderBy: { createdAt: "desc" },
    });
    await app.close();
  });

  it("accept attaches the parent to the family, marks the invite accepted", async () => {
    const app = await buildApp(inviteRoutes, "/v1/family");
    store.set(
      "invite:inv-1",
      JSON.stringify({ familyId: "fam-1", email: "mom@example.com", role: "guardian", permissions: ["location"] }),
    );
    prismaMock.familyInvite.findUnique.mockResolvedValue({ ...INVITE_ROW, role: "guardian", permissions: ["location"] });
    prismaMock.parent.findUnique.mockResolvedValue({
      id: "parent-2",
      familyId: "fam-2",
      email: "Mom@Example.com",
      role: "owner",
      passwordHash: "secret",
      mfaSecret: null,
    });
    prismaMock.parent.update.mockResolvedValue({ id: "parent-2", familyId: "fam-1", role: "guardian", permissions: ["location"] });
    prismaMock.familyInvite.update.mockResolvedValue({ ...INVITE_ROW, status: "accepted" });
    prismaMock.family.findUnique.mockResolvedValue({ id: "fam-1", name: "The Family" });

    const res = await app.inject({
      method: "POST",
      url: "/v1/family/invites/inv-1/accept",
      headers: authHeader(app, "fam-2", "parent-2"),
    });
    expect(res.statusCode).toBe(200);
    expect(prismaMock.parent.update).toHaveBeenCalledWith({
      where: { id: "parent-2" },
      data: { familyId: "fam-1", role: "guardian", permissions: ["location"] },
    });
    expect(prismaMock.familyInvite.update).toHaveBeenCalledWith({
      where: { id: "inv-1" },
      data: { status: "accepted" },
    });
    expect(res.json().family.id).toBe("fam-1");
    expect(res.json().parent.familyId).toBe("fam-1");
    expect(res.json().parent.passwordHash).toBeUndefined();
    expect(res.json().token).toBeDefined();
    await app.close();
  });

  it("accept invalidates sessions minted for the previous family (invalid-before epoch)", async () => {
    const app = await buildApp(inviteRoutes, "/v1/family");
    store.set(
      "invite:inv-1",
      JSON.stringify({ familyId: "fam-1", email: "mom@example.com", role: "co-parent", permissions: [] }),
    );
    prismaMock.familyInvite.findUnique.mockResolvedValue(INVITE_ROW);
    prismaMock.parent.findUnique.mockResolvedValue({
      id: "parent-2",
      familyId: "fam-2",
      email: "mom@example.com",
      role: "owner",
      passwordHash: "secret",
      mfaSecret: null,
    });
    prismaMock.parent.update.mockResolvedValue({ id: "parent-2", familyId: "fam-1", role: "co-parent", permissions: [] });
    prismaMock.familyInvite.update.mockResolvedValue({ ...INVITE_ROW, status: "accepted" });
    prismaMock.family.findUnique.mockResolvedValue({ id: "fam-1", name: "The Family" });
    prismaMock.familyInvite.findMany.mockResolvedValue([]);

    const oldIat = Math.floor(Date.now() / 1000) - 5;
    const oldToken = app.jwt.sign(
      { sub: "parent-2", familyId: "fam-2", role: "parent", jti: "cccccccccccccccccccccccccccccccc", iat: oldIat },
      { expiresIn: "7d" },
    );
    const res = await app.inject({
      method: "POST",
      url: "/v1/family/invites/inv-1/accept",
      headers: { authorization: `Bearer ${oldToken}` },
    });
    expect(res.statusCode).toBe(200);

    const epoch = Number(store.get("auth:invalid-before:parent-2"));
    expect(epoch).toBeGreaterThanOrEqual(oldIat);
    // The freshly minted token was issued after the epoch, so it stays live.
    const freshClaims = app.jwt.decode(res.json().token) as { iat: number; familyId: string };
    expect(freshClaims.familyId).toBe("fam-1");
    expect(freshClaims.iat).toBeGreaterThanOrEqual(epoch);
    const fresh = await app.inject({ method: "GET", url: "/v1/family/invites", headers: { authorization: `Bearer ${res.json().token}` } });
    expect(fresh.statusCode).toBe(200);
    // The token minted for the previous family is dead on a parent-gated route.
    const stale = await app.inject({ method: "GET", url: "/v1/family/invites", headers: { authorization: `Bearer ${oldToken}` } });
    expect(stale.statusCode).toBe(401);
    expect(stale.json().error).toBe("session_revoked");
    await app.close();
  });

  it("accept rejects an email mismatch with 403", async () => {
    const app = await buildApp(inviteRoutes, "/v1/family");
    store.set("invite:inv-1", JSON.stringify({ familyId: "fam-1", email: "mom@example.com", role: "co-parent", permissions: [] }));
    prismaMock.familyInvite.findUnique.mockResolvedValue(INVITE_ROW);
    prismaMock.parent.findUnique.mockResolvedValue({ id: "parent-9", familyId: "fam-9", email: "stranger@example.com" });

    const res = await app.inject({
      method: "POST",
      url: "/v1/family/invites/inv-1/accept",
      headers: authHeader(app, "fam-9", "parent-9"),
    });
    expect(res.statusCode).toBe(403);
    expect(res.json().error).toBe("email_mismatch");
    expect(prismaMock.parent.update).not.toHaveBeenCalled();
    await app.close();
  });

  it("accept returns 404 for an unknown or expired token", async () => {
    const app = await buildApp(inviteRoutes, "/v1/family");
    const res = await app.inject({
      method: "POST",
      url: "/v1/family/invites/inv-missing/accept",
      headers: authHeader(app),
    });
    expect(res.statusCode).toBe(404);
    expect(prismaMock.parent.update).not.toHaveBeenCalled();
    await app.close();
  });

  it("accept returns 409 when the invite is no longer pending", async () => {
    const app = await buildApp(inviteRoutes, "/v1/family");
    store.set("invite:inv-1", JSON.stringify({ familyId: "fam-1", email: "mom@example.com", role: "co-parent", permissions: [] }));
    prismaMock.familyInvite.findUnique.mockResolvedValue({ ...INVITE_ROW, status: "revoked" });

    const res = await app.inject({
      method: "POST",
      url: "/v1/family/invites/inv-1/accept",
      headers: authHeader(app, "fam-1", "parent-2"),
    });
    expect(res.statusCode).toBe(409);
    expect(prismaMock.parent.update).not.toHaveBeenCalled();
    await app.close();
  });

  it("owner revokes an invite (200); non-owner gets 403; other family gets 403", async () => {
    const app = await buildApp(inviteRoutes, "/v1/family");
    prismaMock.parent.findUnique.mockResolvedValue(OWNER);
    prismaMock.familyInvite.findUnique.mockResolvedValue(INVITE_ROW);
    prismaMock.familyInvite.update.mockResolvedValue({ ...INVITE_ROW, status: "revoked" });

    const res = await app.inject({
      method: "DELETE",
      url: "/v1/family/invites/inv-1",
      headers: authHeader(app),
    });
    expect(res.statusCode).toBe(200);
    expect(res.json().invite.status).toBe("revoked");
    expect(prismaMock.familyInvite.update).toHaveBeenCalledWith({ where: { id: "inv-1" }, data: { status: "revoked" } });

    prismaMock.parent.findUnique.mockResolvedValue({ ...OWNER, role: "guardian" });
    const nonOwner = await app.inject({
      method: "DELETE",
      url: "/v1/family/invites/inv-1",
      headers: authHeader(app),
    });
    expect(nonOwner.statusCode).toBe(403);

    prismaMock.parent.findUnique.mockResolvedValue(OWNER);
    prismaMock.familyInvite.findUnique.mockResolvedValue({ ...INVITE_ROW, familyId: "fam-2" });
    const foreign = await app.inject({
      method: "DELETE",
      url: "/v1/family/invites/inv-1",
      headers: authHeader(app, "fam-1"),
    });
    expect(foreign.statusCode).toBe(403);
    await app.close();
  });

  it("refuses the 21st invite from one family in a day and serves the 20th (roadmap 2.7)", async () => {
    const app = await buildApp(inviteRoutes, "/v1/family");
    prismaMock.parent.findUnique.mockResolvedValue(OWNER);
    prismaMock.family.findUnique.mockResolvedValue({ id: "fam-1", name: "Haddad", region: "US" });
    setEmailSender({ name: "noop", send: async () => ({ ok: true as const }) });

    // The limit is a count of the rows a window covers, so the fake is the rows: `count` answers from
    // what `create` actually stored. Mutant: remove the count check in routes/invites.ts -> the 21st
    // answers 201 and one family can mail 20 addresses a second, as often as it likes.
    const rows: Array<{ familyId: string; email: string; createdAt: Date }> = [];
    prismaMock.familyInvite.create.mockImplementation(async ({ data }: { data: Record<string, string> }) => {
      rows.push({ familyId: data.familyId, email: data.email, createdAt: new Date() });
      return { id: `inv-${rows.length}`, status: "pending", permissions: [], ...data };
    });
    prismaMock.familyInvite.count.mockImplementation(
      async ({ where }: { where: { familyId: string; createdAt: { gt: Date } } }) =>
        rows.filter((row) => row.familyId === where.familyId && row.createdAt > where.createdAt.gt).length,
    );

    for (let i = 0; i < 20; i++) {
      const res = await app.inject({
        method: "POST",
        url: "/v1/family/invites",
        headers: authHeader(app),
        payload: { email: `member${i}@example.com`, role: "guardian" },
      });
      expect(res.statusCode).toBe(201);
    }
    const over = await app.inject({
      method: "POST",
      url: "/v1/family/invites",
      headers: authHeader(app),
      payload: { email: "member20@example.com", role: "guardian" },
    });
    expect(over.statusCode).toBe(429);
    expect(over.json()).toEqual({ error: "invite_limit_reached" });
    expect(rows).toHaveLength(20);
    setEmailSender(null);
    await app.close();
  });
});
