import { beforeEach, describe, expect, it, vi } from "vitest";
import Fastify, { type FastifyInstance } from "fastify";
import fastifyJwt from "@fastify/jwt";
import { DEFAULT_BLOCKED_CATEGORIES } from "@familyshield/shared-types";
import { blocklistRoutes } from "../src/routes/blocklists.js";
import { rulesRoutes } from "../src/routes/rules.js";
import { familyRoutes } from "../src/routes/family.js";
import { authHeader, deviceHeader, prismaMock, resetPrismaMock } from "./helpers.js";

vi.mock("../src/db.js", async () => {
  const { prismaMock } = await import("./helpers.js");
  return { prisma: prismaMock };
});
vi.mock("ioredis", async () => {
  const { MockRedis } = await import("./helpers.js");
  return { Redis: MockRedis };
});

const FAMILY = { id: "fam-1", region: "US" };
const CHILD_ID = "child-1";

/** Fastify instance with the blocklists, rules and family routes mounted at their /v1 prefixes. */
async function buildApp(): Promise<FastifyInstance> {
  const app = Fastify({ logger: false });
  await app.register(fastifyJwt, { secret: "test-secret" });
  await app.register(blocklistRoutes, { prefix: "/v1/blocklists" });
  await app.register(rulesRoutes, { prefix: "/v1/rules" });
  await app.register(familyRoutes, { prefix: "/v1/family" });
  await app.ready();
  return app;
}

describe("blocklist pack (Feature #1)", () => {
  beforeEach(() => {
    resetPrismaMock();
  });

  it("rejects GET /v1/blocklists without a token (401)", async () => {
    const app = await buildApp();
    const res = await app.inject({ method: "GET", url: "/v1/blocklists" });
    expect(res.statusCode).toBe(401);
    expect(res.json().error).toBe("unauthorized");
    await app.close();
  });

  it("serves the pack to a parent token with all 13 default categories and non-empty domains", async () => {
    const app = await buildApp();
    const res = await app.inject({ method: "GET", url: "/v1/blocklists", headers: authHeader(app) });
    expect(res.statusCode).toBe(200);
    const body = res.json();
    expect(body.version).toBe(1);
    expect(typeof body.updatedAt).toBe("string");
    expect(body.categories).toHaveLength(DEFAULT_BLOCKED_CATEGORIES.length);
    const names = body.categories.map((c: { category: string }) => c.category).sort();
    expect(names).toEqual([...DEFAULT_BLOCKED_CATEGORIES].sort());
    for (const entry of body.categories) {
      expect(Array.isArray(entry.domains)).toBe(true);
      expect(entry.domains.length).toBeGreaterThan(0);
      expect(Array.isArray(entry.appsAndroid)).toBe(true);
      expect(Array.isArray(entry.appsWindows)).toBe(true);
      expect(entry.domains.every((d: string) => d === d.toLowerCase())).toBe(true);
    }
    await app.close();
  });

  it("serves the pack to a device token (requireAuth is role-agnostic)", async () => {
    const app = await buildApp();
    const res = await app.inject({ method: "GET", url: "/v1/blocklists", headers: deviceHeader(app) });
    expect(res.statusCode).toBe(200);
    expect(res.json().categories).toHaveLength(DEFAULT_BLOCKED_CATEGORIES.length);
    await app.close();
  });

  it("returns the 13 default blocked categories when a child has no ruleset row", async () => {
    const app = await buildApp();
    prismaMock.child.findUnique.mockResolvedValue({ id: CHILD_ID, familyId: FAMILY.id });
    prismaMock.ruleSet.findUnique.mockResolvedValue(null);
    const res = await app.inject({ method: "GET", url: `/v1/rules/${CHILD_ID}`, headers: authHeader(app) });
    expect(res.statusCode).toBe(200);
    expect(res.json().webFilter.blockedCategories).toEqual([...DEFAULT_BLOCKED_CATEGORIES]);
    await app.close();
  });

  it("creates the default ruleset alongside an inline-consent child (201)", async () => {
    const app = await buildApp();
    prismaMock.family.findUnique.mockResolvedValue(FAMILY);
    prismaMock.child.create.mockResolvedValue({ id: "child-inline", familyId: FAMILY.id, displayName: "Sam" });
    prismaMock.consentRecord.create.mockResolvedValue({ id: "consent-inline", method: "sms_plus" });

    const res = await app.inject({
      method: "POST",
      url: "/v1/family/children",
      headers: authHeader(app),
      payload: { displayName: "Sam", birthYear: 2014, consent: { method: "sms_plus", jurisdiction: "US" } },
    });
    expect(res.statusCode).toBe(201);
    expect(prismaMock.ruleSet.upsert).toHaveBeenCalledWith(
      expect.objectContaining({
        where: { childId: "child-inline" },
        create: expect.objectContaining({ blockedCategories: [...DEFAULT_BLOCKED_CATEGORIES] }),
      }),
    );
    expect(res.json().child.id).toBe("child-inline");
    await app.close();
  });
});
