import { beforeEach, describe, expect, it, vi } from "vitest";
import Fastify, { type FastifyInstance } from "fastify";
import fastifyJwt from "@fastify/jwt";
import { deviceRoutes } from "../src/routes/devices.js";
import { rulesRoutes } from "../src/routes/rules.js";
import { familyRoutes } from "../src/routes/family.js";
import { locationRoutes } from "../src/routes/location.js";
import { getRedis } from "../src/redis.js";
import { PAIR_SCRIPTS } from "../src/lib/pairApproval.js";
import { MockRedis, authHeader, buildApp, deviceHeader, prismaMock, resetPrismaMock } from "./helpers.js";

vi.mock("../src/db.js", async () => {
  const { prismaMock } = await import("./helpers.js");
  return { prisma: prismaMock };
});
vi.mock("ioredis", async () => {
  const { MockRedis } = await import("./helpers.js");
  return { Redis: MockRedis };
});

/** In-memory Redis state so pair/claim round-trips behave like a real store. */
const store = new Map<string, string>();

function wireRedis(): MockRedis {
  const redis = getRedis() as unknown as MockRedis;
  redis.get.mockImplementation(async (key: string) => store.get(key) ?? null);
  redis.set.mockImplementation(async (key: string, value: unknown) => {
    store.set(key, String(value));
    return "OK";
  });
  redis.del.mockImplementation(async (...keys: string[]) =>
    keys.reduce((n, k) => n + (store.delete(k) ? 1 : 0), 0),
  );
  // The pairing-approval scripts (lib/pairApproval.ts), emulated by name on the same store. TTLs are not
  // modelled: an expiry is a deleted key, which is what the tests do to expire a code.
  redis.eval.mockImplementation(async (script: string, _n: number, ...args: string[]) => {
    if (script === PAIR_SCRIPTS.reserve) {
      const [code, claim, claimId] = args;
      const value = store.get(code);
      if (value === undefined) return [0];
      if (store.has(claim)) return [2];
      store.set(claim, claimId);
      return [1, value, 600_000];
    }
    if (script === PAIR_SCRIPTS.compareAndSet) {
      const [key, expected, next] = args;
      if (store.get(key) !== expected) return 0;
      store.set(key, next);
      return 1;
    }
    if (script === PAIR_SCRIPTS.compareAndDelete) {
      const [key, expected] = args;
      if (store.get(key) !== expected) return 0;
      store.delete(key);
      return 1;
    }
    throw new Error(`unexpected script: ${script}`);
  });
  redis.publish.mockResolvedValue(1);
  redis.lpush.mockResolvedValue(1);
  redis.ltrim.mockResolvedValue("OK");
  redis.lrange.mockResolvedValue([]);
  return redis;
}

/** Build one app with every route family mounted, mirroring server.ts wiring. */
async function buildFullApp(): Promise<FastifyInstance> {
  const app = Fastify({ logger: false });
  await app.register(fastifyJwt, { secret: "test-secret" });
  await app.register(deviceRoutes, { prefix: "/v1/devices" });
  await app.register(rulesRoutes, { prefix: "/v1/rules" });
  await app.register(familyRoutes, { prefix: "/v1/family" });
  await app.register(locationRoutes, { prefix: "/v1/location" });
  await app.ready();
  return app;
}

describe("device pairing (spec §14.1)", () => {
  beforeEach(() => {
    resetPrismaMock();
    store.clear();
    wireRedis();
  });

  it("POST /pair (parent JWT) returns a 6-digit code stored with a 600 s TTL", async () => {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    prismaMock.child.findUnique.mockResolvedValue({ id: "child-1", familyId: "fam-1" });

    const res = await app.inject({
      method: "POST",
      url: "/v1/devices/pair",
      headers: authHeader(app),
      payload: { childId: "child-1" },
    });
    expect(res.statusCode).toBe(201);
    const body = res.json();
    expect(body.code).toMatch(/^\d{6}$/);
    const ttlMs = new Date(body.expiresAt).getTime() - Date.now();
    expect(ttlMs).toBeGreaterThan(590_000);
    expect(ttlMs).toBeLessThanOrEqual(600_000);
    expect(store.get(`pair:${body.code}`)).toBe(JSON.stringify({ childId: "child-1", familyId: "fam-1" }));
    const redis = getRedis() as unknown as MockRedis;
    expect(redis.set).toHaveBeenCalledWith(
      `pair:${body.code}`,
      JSON.stringify({ childId: "child-1", familyId: "fam-1" }),
      "EX",
      600,
      "NX",
    );
    await app.close();
  });

  // Issue #138: a pairing code is redeemed for a device JWT and a per-device HMAC secret at
  // `/pair/claim`, so minting one requires the `devices` permission (ADR-0014 amendment).
  it("POST /pair requires the devices permission: co-parent without it 403, with it 201", async () => {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    prismaMock.child.findUnique.mockResolvedValue({ id: "child-1", familyId: "fam-1" });

    prismaMock.parent.findUnique.mockResolvedValue({ id: "p-co", familyId: "fam-1", role: "co-parent", permissions: ["alerts"] });
    const denied = await app.inject({
      method: "POST",
      url: "/v1/devices/pair",
      headers: authHeader(app, "fam-1", "p-co"),
      payload: { childId: "child-1" },
    });
    expect(denied.statusCode).toBe(403);
    expect(denied.json()).toEqual({ error: "permission_required", permission: "devices" });
    expect(prismaMock.child.findUnique).not.toHaveBeenCalled();
    expect(store.size).toBe(0);

    prismaMock.parent.findUnique.mockResolvedValue({ id: "p-co", familyId: "fam-1", role: "co-parent", permissions: ["devices"] });
    const allowed = await app.inject({
      method: "POST",
      url: "/v1/devices/pair",
      headers: authHeader(app, "fam-1", "p-co"),
      payload: { childId: "child-1" },
    });
    expect(allowed.statusCode).toBe(201);
    expect(allowed.json().code).toMatch(/^\d{6}$/);
    await app.close();
  });

  it("POST /pair returns 400 on a bad body and 403 for a child outside the family", async () => {
    const app = await buildApp(deviceRoutes, "/v1/devices");

    const bad = await app.inject({
      method: "POST",
      url: "/v1/devices/pair",
      headers: authHeader(app),
      payload: {},
    });
    expect(bad.statusCode).toBe(400);

    prismaMock.child.findUnique.mockResolvedValue({ id: "child-1", familyId: "fam-2" });
    const forbidden = await app.inject({
      method: "POST",
      url: "/v1/devices/pair",
      headers: authHeader(app, "fam-1"),
      payload: { childId: "child-1" },
    });
    expect(forbidden.statusCode).toBe(403);
    await app.close();
  });

  it("POST /pair rejects device tokens (403) — parent-only mutation", async () => {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    const res = await app.inject({
      method: "POST",
      url: "/v1/devices/pair",
      headers: deviceHeader(app),
      payload: { childId: "child-1" },
    });
    expect(res.statusCode).toBe(403);
    expect(res.json().error).toBe("parent_role_required");
    expect(prismaMock.child.findUnique).not.toHaveBeenCalled();
    await app.close();
  });

  /** Claim, Allow as the family's parent, then poll: the whole approval flow, returning each step. */
  async function pairThrough(app: FastifyInstance, payload: Record<string, unknown>) {
    const claim = await app.inject({ method: "POST", url: "/v1/devices/pair/claim", payload });
    const { claimId, pollSecret } = claim.json() as { claimId: string; pollSecret: string };
    const approve = await app.inject({ method: "POST", url: `/v1/devices/pair/claims/${claimId}/approve`, headers: authHeader(app) });
    const poll = await app.inject({ method: "POST", url: `/v1/devices/pair/claims/${claimId}/poll`, payload: { pollSecret } });
    return { claim, approve, poll, claimId, pollSecret };
  }

  // osra-security#3 PR 2: a code alone no longer buys a device. Mutant: mint the token in the claim
  // handler again -> the claim answers 201 and a device is created before anyone approved it.
  it("POST /pair/claim records a pending claim: 202 with a claim id and poll secret, no device, no token", async () => {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    store.set("pair:123456", JSON.stringify({ childId: "child-1", familyId: "fam-1" }));
    const res = await app.inject({
      method: "POST",
      url: "/v1/devices/pair/claim",
      payload: { code: "123456", platform: "android", model: "Pixel 7a", osVersion: "14" },
    });
    expect(res.statusCode).toBe(202);
    const body = res.json();
    expect(body.claimId).toEqual(expect.any(String));
    expect(body.pollSecret).toMatch(/^[A-Za-z0-9_-]{43}$/);
    expect(body).not.toHaveProperty("token");
    expect(body).not.toHaveProperty("hmacSecret");
    expect(prismaMock.device.create).not.toHaveBeenCalled();
    // Only the secret's hash is stored, and the code stays until the parent decides.
    const record = JSON.parse(store.get(`pairclaim:${body.claimId}`)!);
    expect(record.status).toBe("pending");
    expect(JSON.stringify(record)).not.toContain(body.pollSecret);
    expect(store.has("pair:123456")).toBe(true);

    const poll = await app.inject({ method: "POST", url: `/v1/devices/pair/claims/${body.claimId}/poll`, payload: { pollSecret: body.pollSecret } });
    expect(poll.statusCode).toBe(202);
    expect(poll.json()).toEqual({ status: "pending" });
    expect(prismaMock.device.create).not.toHaveBeenCalled();
    await app.close();
  });

  it("after the parent's Allow, the poll creates the device and mints a device JWT", async () => {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    store.set("pair:123456", JSON.stringify({ childId: "child-1", familyId: "fam-1" }));
    prismaMock.device.create.mockImplementation(async ({ data }: { data: Record<string, unknown> }) => ({
      id: "dev-9",
      ...data,
    }));

    const { claim, approve, poll } = await pairThrough(app, {
      code: "123456",
      platform: "android",
      model: "Pixel 7a",
      osVersion: "14",
      deviceName: "Alex's Phone",
      pushToken: "tok-1",
      // Client-supplied ids must be ignored — the server takes them from the Redis payload.
      childId: "evil-child",
      familyId: "fam-9",
    });
    expect(claim.statusCode).toBe(202);
    expect(approve.statusCode).toBe(200);
    expect(approve.json()).toEqual({ status: "approved" });
    expect(poll.statusCode).toBe(201);
    const body = poll.json();
    expect(body.childId).toBe("child-1");
    expect(body.familyId).toBe("fam-1");
    expect(body.device.id).toBe("dev-9");
    expect(body.device.childId).toBe("child-1");
    expect(body.device.status).toBe("online");
    expect(body.device.model).toBe("Alex's Phone"); // deviceName wins over model
    expect(body.device.pushToken).toBe("tok-1");
    expect(body.device).not.toHaveProperty("familyId");

    const decoded = app.jwt.verify<{ sub: string; deviceId: string; childId: string; familyId: string; role: string; exp?: number }>(
      body.token,
    );
    expect(decoded.role).toBe("device");
    expect(decoded.sub).toBe("dev-9");
    expect(decoded.deviceId).toBe("dev-9");
    expect(decoded.childId).toBe("child-1");
    expect(decoded.familyId).toBe("fam-1");
    expect(decoded.exp).toBeGreaterThan(Date.now() / 1000 + 9 * 365 * 86400); // ~10y validity

    // The code is burned once the device exists.
    expect(store.has("pair:123456")).toBe(false);
    await app.close();
  });

  it("the poll returns the per-device HMAC secret so agents can sign alerts (BUG-001)", async () => {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    store.set("pair:111111", JSON.stringify({ childId: "child-1", familyId: "fam-1" }));
    prismaMock.device.create.mockResolvedValue({ id: "dev-h", childId: "child-1" });
    const previous = process.env.INTERNAL_HMAC_SECRET;
    process.env.INTERNAL_HMAC_SECRET = "claim-secret-abc";

    const { poll } = await pairThrough(app, { code: "111111", platform: "android", model: "Pixel", osVersion: "14" });
    expect(poll.statusCode).toBe(201);
    // Handoff item 5: a freshly minted PER-DEVICE secret (64 hex chars), never the global INTERNAL_HMAC_SECRET.
    const secret = poll.json().hmacSecret;
    expect(secret).toMatch(/^[0-9a-f]{64}$/);
    expect(secret).not.toBe("claim-secret-abc");
    if (previous === undefined) delete process.env.INTERNAL_HMAC_SECRET;
    else process.env.INTERNAL_HMAC_SECRET = previous;
    await app.close();
  });

  // Mutant: drop the SET NX on `pair:<code>:claim` -> both claims answer 202 and the parent sees two.
  it("concurrent claims of the same code: exactly one is pending, the other is refused (BUG-005)", async () => {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    store.set("pair:222222", JSON.stringify({ childId: "child-1", familyId: "fam-1" }));
    const [first, second] = await Promise.all([
      app.inject({ method: "POST", url: "/v1/devices/pair/claim", payload: { code: "222222", platform: "android", model: "A", osVersion: "1" } }),
      app.inject({ method: "POST", url: "/v1/devices/pair/claim", payload: { code: "222222", platform: "windows", model: "B", osVersion: "10" } }),
    ]);
    const statuses = [first.statusCode, second.statusCode].sort((a, b) => a - b);
    expect(statuses).toEqual([202, 409]);
    expect([first, second].find((r) => r.statusCode === 409)!.json().error).toBe("claim_pending");
    expect(prismaMock.device.create).not.toHaveBeenCalled();
    await app.close();
  });

  // Mutant: take the approved claim with a plain GET instead of the compare-and-delete -> both polls mint.
  it("an approved claim hands out its token exactly once, even to two polls at the same moment", async () => {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    store.set("pair:333333", JSON.stringify({ childId: "child-1", familyId: "fam-1" }));
    let seq = 0;
    prismaMock.device.create.mockImplementation(async () => ({ id: `dev-${seq++}`, childId: "child-1" }));
    const claim = (await app.inject({ method: "POST", url: "/v1/devices/pair/claim", payload: { code: "333333", platform: "android", model: "A", osVersion: "1" } })).json();
    await app.inject({ method: "POST", url: `/v1/devices/pair/claims/${claim.claimId}/approve`, headers: authHeader(app) });
    const polls = await Promise.all([1, 2].map(() =>
      app.inject({ method: "POST", url: `/v1/devices/pair/claims/${claim.claimId}/poll`, payload: { pollSecret: claim.pollSecret } }),
    ));
    expect(polls.map((p) => p.statusCode).sort((a, b) => a - b)).toEqual([201, 404]);
    expect(seq).toBe(1);
    const again = await app.inject({ method: "POST", url: `/v1/devices/pair/claims/${claim.claimId}/poll`, payload: { pollSecret: claim.pollSecret } });
    expect(again.statusCode).toBe(404);
    expect(seq).toBe(1);
    await app.close();
  });

  // Mutant: leave the code in place on Deny -> the second claim answers 409 (or 202), not 404.
  it("Deny: the poll answers 410, no device is created, and the code is burned", async () => {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    store.set("pair:444444", JSON.stringify({ childId: "child-1", familyId: "fam-1" }));
    const claim = (await app.inject({ method: "POST", url: "/v1/devices/pair/claim", payload: { code: "444444", platform: "android", model: "Unknown", osVersion: "1" } })).json();
    const deny = await app.inject({ method: "POST", url: `/v1/devices/pair/claims/${claim.claimId}/deny`, headers: authHeader(app) });
    expect(deny.statusCode).toBe(200);
    expect(deny.json()).toEqual({ status: "denied" });
    const poll = await app.inject({ method: "POST", url: `/v1/devices/pair/claims/${claim.claimId}/poll`, payload: { pollSecret: claim.pollSecret } });
    expect(poll.statusCode).toBe(410);
    expect(poll.json().error).toBe("claim_denied");
    expect(store.has("pair:444444")).toBe(false);
    const reclaim = await app.inject({ method: "POST", url: "/v1/devices/pair/claim", payload: { code: "444444", platform: "android", model: "Unknown", osVersion: "1" } });
    expect(reclaim.statusCode).toBe(404);
    // A decided claim cannot be decided again.
    const lateAllow = await app.inject({ method: "POST", url: `/v1/devices/pair/claims/${claim.claimId}/approve`, headers: authHeader(app) });
    expect(lateAllow.statusCode).toBe(409);
    expect(prismaMock.device.create).not.toHaveBeenCalled();
    await app.close();
  });

  // Mutant: skip pollSecretMatches -> the claim id alone (which the parent's screen shows) gets the token.
  it("a poll with the wrong secret is a 404, even after the parent approved", async () => {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    store.set("pair:555555", JSON.stringify({ childId: "child-1", familyId: "fam-1" }));
    const claim = (await app.inject({ method: "POST", url: "/v1/devices/pair/claim", payload: { code: "555555", platform: "android", model: "A", osVersion: "1" } })).json();
    await app.inject({ method: "POST", url: `/v1/devices/pair/claims/${claim.claimId}/approve`, headers: authHeader(app) });
    const wrong = await app.inject({ method: "POST", url: `/v1/devices/pair/claims/${claim.claimId}/poll`, payload: { pollSecret: "x".repeat(43) } });
    expect(wrong.statusCode).toBe(404);
    expect(wrong.json().error).toBe("claim_not_found");
    expect(prismaMock.device.create).not.toHaveBeenCalled();
    // The real phone still gets its token.
    prismaMock.device.create.mockResolvedValue({ id: "dev-r", childId: "child-1" });
    const right = await app.inject({ method: "POST", url: `/v1/devices/pair/claims/${claim.claimId}/poll`, payload: { pollSecret: claim.pollSecret } });
    expect(right.statusCode).toBe(201);
    await app.close();
  });

  // Mutant: drop the familyId comparison in the approve route -> another family's parent pairs a phone here.
  it("another family's parent can neither see nor decide the claim (404), and nothing is created", async () => {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    store.set("pair:666666", JSON.stringify({ childId: "child-1", familyId: "fam-1" }));
    const claim = (await app.inject({ method: "POST", url: "/v1/devices/pair/claim", payload: { code: "666666", platform: "android", model: "A", osVersion: "1" } })).json();
    prismaMock.parent.findUnique.mockResolvedValue({ id: "parent-9", familyId: "fam-9", role: "owner", permissions: [] });
    const other = authHeader(app, "fam-9", "parent-9");
    const view = await app.inject({ method: "GET", url: "/v1/devices/pair/666666/claim", headers: other });
    expect(view.statusCode).toBe(404);
    const approve = await app.inject({ method: "POST", url: `/v1/devices/pair/claims/${claim.claimId}/approve`, headers: other });
    expect(approve.statusCode).toBe(404);
    const deny = await app.inject({ method: "POST", url: `/v1/devices/pair/claims/${claim.claimId}/deny`, headers: other });
    expect(deny.statusCode).toBe(404);
    const poll = await app.inject({ method: "POST", url: `/v1/devices/pair/claims/${claim.claimId}/poll`, payload: { pollSecret: claim.pollSecret } });
    expect(poll.statusCode).toBe(202);
    expect(prismaMock.device.create).not.toHaveBeenCalled();
    await app.close();
  });

  it("deciding a claim needs the devices permission, like minting the code (403 without it)", async () => {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    store.set("pair:777777", JSON.stringify({ childId: "child-1", familyId: "fam-1" }));
    const claim = (await app.inject({ method: "POST", url: "/v1/devices/pair/claim", payload: { code: "777777", platform: "android", model: "A", osVersion: "1" } })).json();
    prismaMock.parent.findUnique.mockResolvedValue({ id: "p-co", familyId: "fam-1", role: "co-parent", permissions: ["alerts"] });
    const res = await app.inject({ method: "POST", url: `/v1/devices/pair/claims/${claim.claimId}/approve`, headers: authHeader(app, "fam-1", "p-co") });
    expect(res.statusCode).toBe(403);
    expect(res.json()).toEqual({ error: "permission_required", permission: "devices" });
    await app.close();
  });

  it("GET /pair/:code/claim follows the code: waiting, pending with the phone's details, then paired", async () => {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    store.set("pair:888888", JSON.stringify({ childId: "child-1", familyId: "fam-1" }));
    prismaMock.device.create.mockResolvedValue({ id: "dev-p", childId: "child-1" });
    const url = "/v1/devices/pair/888888/claim";
    expect((await app.inject({ method: "GET", url, headers: authHeader(app) })).json()).toEqual({ status: "waiting" });
    const claim = (await app.inject({ method: "POST", url: "/v1/devices/pair/claim", payload: { code: "888888", platform: "android", model: "Pixel 8", osVersion: "15", deviceName: "Sam's phone" } })).json();
    const pending = await app.inject({ method: "GET", url, headers: authHeader(app) });
    expect(pending.json()).toEqual({ status: "pending", claimId: claim.claimId, platform: "android", model: "Pixel 8", deviceName: "Sam's phone", osVersion: "15" });
    expect(JSON.stringify(pending.json())).not.toContain(claim.pollSecret);
    await app.inject({ method: "POST", url: `/v1/devices/pair/claims/${claim.claimId}/approve`, headers: authHeader(app) });
    expect((await app.inject({ method: "GET", url, headers: authHeader(app) })).json().status).toBe("approved");
    await app.inject({ method: "POST", url: `/v1/devices/pair/claims/${claim.claimId}/poll`, payload: { pollSecret: claim.pollSecret } });
    const paired = (await app.inject({ method: "GET", url, headers: authHeader(app) })).json();
    expect(paired.status).toBe("paired");
    expect(paired.deviceId).toBe("dev-p");
    expect((await app.inject({ method: "GET", url: "/v1/devices/pair/999999/claim", headers: authHeader(app) })).statusCode).toBe(404);
    await app.close();
  });

  // The claim lives no longer than the code (both keys carry the code's remaining TTL). Expiry is a
  // deleted key here; the real TTL is pinned by the probe on a live Redis.
  it("a claim that expires while pending: the poll and the parent's decision both answer 404", async () => {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    store.set("pair:121212", JSON.stringify({ childId: "child-1", familyId: "fam-1" }));
    const claim = (await app.inject({ method: "POST", url: "/v1/devices/pair/claim", payload: { code: "121212", platform: "android", model: "A", osVersion: "1" } })).json();
    for (const key of ["pair:121212", "pair:121212:claim", `pairclaim:${claim.claimId}`]) store.delete(key);
    const poll = await app.inject({ method: "POST", url: `/v1/devices/pair/claims/${claim.claimId}/poll`, payload: { pollSecret: claim.pollSecret } });
    expect(poll.statusCode).toBe(404);
    const approve = await app.inject({ method: "POST", url: `/v1/devices/pair/claims/${claim.claimId}/approve`, headers: authHeader(app) });
    expect(approve.statusCode).toBe(404);
    expect(prismaMock.device.create).not.toHaveBeenCalled();
    await app.close();
  });

  // Consent can be withdrawn while the parent decides; the device is created only if it still holds.
  it("consent withdrawn between Allow and the poll: 428 and no device", async () => {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    store.set("pair:131313", JSON.stringify({ childId: "child-1", familyId: "fam-1" }));
    const claim = (await app.inject({ method: "POST", url: "/v1/devices/pair/claim", payload: { code: "131313", platform: "android", model: "A", osVersion: "1" } })).json();
    await app.inject({ method: "POST", url: `/v1/devices/pair/claims/${claim.claimId}/approve`, headers: authHeader(app) });
    prismaMock.consentRecord.findFirst.mockResolvedValue(null);
    const poll = await app.inject({ method: "POST", url: `/v1/devices/pair/claims/${claim.claimId}/poll`, payload: { pollSecret: claim.pollSecret } });
    expect(poll.statusCode).toBe(428);
    expect(prismaMock.device.create).not.toHaveBeenCalled();
    await app.close();
  });

  it("POST /pair/claim falls back to model when deviceName is absent", async () => {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    store.set("pair:654321", JSON.stringify({ childId: "child-1", familyId: "fam-1" }));
    prismaMock.device.create.mockImplementation(async ({ data }: { data: Record<string, unknown> }) => ({
      id: "dev-10",
      ...data,
    }));
    const { poll } = await pairThrough(app, { code: "654321", platform: "windows", model: "Surface Go", osVersion: "11" });
    expect(poll.statusCode).toBe(201);
    expect(poll.json().device.model).toBe("Surface Go");
    await app.close();
  });

  it("POST /pair/claim returns 400 for a malformed claim body", async () => {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    const badCode = await app.inject({
      method: "POST",
      url: "/v1/devices/pair/claim",
      payload: { code: "12345", platform: "android", model: "Pixel", osVersion: "14" },
    });
    expect(badCode.statusCode).toBe(400);

    const badPlatform = await app.inject({
      method: "POST",
      url: "/v1/devices/pair/claim",
      payload: { code: "123456", platform: "toaster", model: "Pixel", osVersion: "14" },
    });
    expect(badPlatform.statusCode).toBe(400);

    const missingFields = await app.inject({
      method: "POST",
      url: "/v1/devices/pair/claim",
      payload: { code: "123456" },
    });
    expect(missingFields.statusCode).toBe(400);

    // The parent reads these on the Allow / Deny screen, so they are bounded.
    const longName = await app.inject({
      method: "POST",
      url: "/v1/devices/pair/claim",
      payload: { code: "123456", platform: "android", model: "Pixel", osVersion: "14", deviceName: "x".repeat(101) },
    });
    expect(longName.statusCode).toBe(400);
    expect(prismaMock.device.create).not.toHaveBeenCalled();
    await app.close();
  });

  it("POST /pair/claim returns 404 for an unknown or expired code", async () => {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    const res = await app.inject({
      method: "POST",
      url: "/v1/devices/pair/claim",
      payload: { code: "000000", platform: "android", model: "Pixel", osVersion: "14" },
    });
    expect(res.statusCode).toBe(404);
    expect(res.json().error).toBe("invalid_or_expired_code");
    expect(prismaMock.device.create).not.toHaveBeenCalled();
    await app.close();
  });

  it("a code that already produced a device cannot be claimed again (404)", async () => {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    store.set("pair:111222", JSON.stringify({ childId: "child-1", familyId: "fam-1" }));
    prismaMock.device.create.mockImplementation(async ({ data }: { data: Record<string, unknown> }) => ({
      id: "dev-11",
      ...data,
    }));
    const payload = { code: "111222", platform: "android", model: "Pixel", osVersion: "14" };
    const { poll } = await pairThrough(app, payload);
    expect(poll.statusCode).toBe(201);

    const second = await app.inject({ method: "POST", url: "/v1/devices/pair/claim", payload });
    expect(second.statusCode).toBe(404);
    expect(second.json().error).toBe("invalid_or_expired_code");
    expect(prismaMock.device.create).toHaveBeenCalledTimes(1);
    await app.close();
  });
});

describe("device JWT compatibility (spec §14.1)", () => {
  beforeEach(() => {
    resetPrismaMock();
    store.clear();
    wireRedis();
  });

  it("rejects device tokens (403) from POST /v1/family/children", async () => {
    const app = await buildFullApp();
    const res = await app.inject({
      method: "POST",
      url: "/v1/family/children",
      headers: deviceHeader(app),
      payload: { displayName: "Alex", birthYear: 2013 },
    });
    expect(res.statusCode).toBe(403);
    expect(res.json().error).toBe("parent_role_required");
    expect(prismaMock.child.create).not.toHaveBeenCalled();
    await app.close();
  });

  it("rejects device tokens (403) from PUT /v1/rules/:childId", async () => {
    const app = await buildFullApp();
    const res = await app.inject({
      method: "PUT",
      url: "/v1/rules/child-1",
      headers: deviceHeader(app),
      payload: {},
    });
    expect(res.statusCode).toBe(403);
    expect(res.json().error).toBe("parent_role_required");
    expect(prismaMock.ruleSet.upsert).not.toHaveBeenCalled();
    await app.close();
  });

  it("accepts device tokens (200) from GET /v1/rules/:childId", async () => {
    const app = await buildFullApp();
    prismaMock.child.findUnique.mockResolvedValue({ id: "child-1", familyId: "fam-1" });
    prismaMock.ruleSet.findUnique.mockResolvedValue(null);

    const res = await app.inject({
      method: "GET",
      url: "/v1/rules/child-1",
      headers: deviceHeader(app),
    });
    expect(res.statusCode).toBe(200);
    expect(res.json().childId).toBe("child-1");
    await app.close();
  });

  it("accepts device tokens (202) from POST /v1/devices/:id/telemetry", async () => {
    const app = await buildFullApp();
    prismaMock.device.findUnique.mockResolvedValue({ id: "dev-1", child: { familyId: "fam-1" } });

    const res = await app.inject({
      method: "POST",
      url: "/v1/devices/dev-1/telemetry",
      headers: deviceHeader(app),
      payload: { batteryPct: 80, appUsage: [{ packageId: "com.game", minutes: 12 }] },
    });
    expect(res.statusCode).toBe(202);
    expect(store.get("device:dev-1:telemetry")).toContain('"batteryPct":80');
    await app.close();
  });

  it("accepts device tokens (201) from POST /v1/location/ping", async () => {
    const app = await buildFullApp();
    prismaMock.child.findUnique.mockResolvedValue({ id: "child-1", familyId: "fam-1" });
    prismaMock.geofence.findMany.mockResolvedValue([]);
    prismaMock.locationPing.create.mockResolvedValue({ id: "ping-1" });

    const res = await app.inject({
      method: "POST",
      url: "/v1/location/ping",
      headers: deviceHeader(app),
      payload: { childId: "child-1", deviceId: "dev-1", lat: 40.7128, lng: -74.006, accuracyM: 5 },
    });
    expect(res.statusCode).toBe(201);
    expect(res.json().ping.id).toBe("ping-1");
    await app.close();
  });
});
