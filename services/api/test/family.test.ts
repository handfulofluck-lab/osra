import { beforeEach, describe, expect, it, vi } from "vitest";
import { familyRoutes } from "../src/routes/family.js";
import { MockRedis, authHeader, buildApp, deviceHeader, prismaMock, resetPrismaMock } from "./helpers.js";

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

describe("family routes", () => {
  beforeEach(() => {
    resetPrismaMock();
  });

  it("returns 428 when creating a child without an active consent record", async () => {
    const app = await buildApp(familyRoutes, "/v1/family");
    prismaMock.family.findUnique.mockResolvedValue(FAMILY);
    prismaMock.consentRecord.findFirst.mockResolvedValue(null);

    const res = await app.inject({
      method: "POST",
      url: "/v1/family/children",
      headers: authHeader(app),
      payload: { displayName: "Alex", birthYear: 2013 },
    });
    expect(res.statusCode).toBe(428);
    expect(res.json().error).toBe("parental_consent_required");
    expect(prismaMock.child.create).not.toHaveBeenCalled();
    await app.close();
  });

  it("still returns 428 without inline consent even when the family has an active consent (strict gate)", async () => {
    const app = await buildApp(familyRoutes, "/v1/family");
    prismaMock.family.findUnique.mockResolvedValue(FAMILY);
    prismaMock.consentRecord.findFirst.mockResolvedValue({ id: "consent-1", jurisdiction: "US" });

    const res = await app.inject({
      method: "POST",
      url: "/v1/family/children",
      headers: authHeader(app),
      payload: { displayName: "Alex", birthYear: 2013 },
    });
    // Consent belongs to an existing child; it cannot be re-linked to a new one.
    expect(res.statusCode).toBe(428);
    expect(prismaMock.child.create).not.toHaveBeenCalled();
    await app.close();
  });

  it("creates a child and consent atomically when consent is inline (201)", async () => {
    const app = await buildApp(familyRoutes, "/v1/family");
    prismaMock.family.findUnique.mockResolvedValue(FAMILY);
    prismaMock.child.create.mockResolvedValue({ id: "child-inline", displayName: "Sam" });
    prismaMock.consentRecord.create.mockResolvedValue({ id: "consent-inline", method: "sms_plus" });

    const res = await app.inject({
      method: "POST",
      url: "/v1/family/children",
      headers: authHeader(app),
      payload: { displayName: "Sam", birthYear: 2014, consent: { method: "sms_plus", jurisdiction: "US" } },
    });
    expect(res.statusCode).toBe(201);
    expect(prismaMock.consentRecord.create).toHaveBeenCalledWith(
      expect.objectContaining({ data: expect.objectContaining({ method: "sms_plus", jurisdiction: "US" }) }),
    );
    await app.close();
  });

  it("returns 428 when inline consent jurisdiction does not match the family region", async () => {
    const app = await buildApp(familyRoutes, "/v1/family");
    prismaMock.family.findUnique.mockResolvedValue(FAMILY);

    const res = await app.inject({
      method: "POST",
      url: "/v1/family/children",
      headers: authHeader(app),
      payload: { displayName: "Sam", birthYear: 2014, consent: { method: "sms_plus", jurisdiction: "EU" } },
    });
    expect(res.statusCode).toBe(428);
    expect(res.json().error).toBe("consent_jurisdiction_mismatch");
    expect(prismaMock.child.create).not.toHaveBeenCalled();
    await app.close();
  });

  it("returns the /me envelope with family, parent, children and flat devices", async () => {
    const app = await buildApp(familyRoutes, "/v1/family");
    prismaMock.family.findUnique.mockResolvedValue({
      id: FAMILY.id,
      name: "Demo",
      region: "US",
      createdAt: new Date().toISOString(),
      parents: [{ id: "parent-1", email: "demo@familyshield.dev", passwordHash: "argon2$secret", mfaSecret: "mfa" }],
      children: [
        { id: CHILD_ID, displayName: "Alex", devices: [{ id: "dev-1" }], ruleSet: { id: "rs-1" }, consents: [], geofences: [] },
      ],
    });

    const res = await app.inject({ method: "GET", url: "/v1/family/me", headers: authHeader(app) });
    expect(res.statusCode).toBe(200);
    const body = res.json();
    expect(body.family.id).toBe(FAMILY.id);
    expect(body.parent.id).toBe("parent-1");
    expect(body.parent.passwordHash).toBeUndefined();
    expect(body.children).toHaveLength(1);
    expect(body.devices).toHaveLength(1);
    expect(JSON.stringify(body)).not.toContain("passwordHash");
    await app.close();
  });

  it("returns a single child of the family (200) and 404 for an unknown id", async () => {
    const app = await buildApp(familyRoutes, "/v1/family");
    prismaMock.child.findUnique.mockResolvedValue({ id: CHILD_ID, familyId: "fam-1", displayName: "Alex" });

    const res = await app.inject({
      method: "GET",
      url: `/v1/family/children/${CHILD_ID}`,
      headers: authHeader(app),
    });
    expect(res.statusCode).toBe(200);
    expect(res.json().displayName).toBe("Alex");

    prismaMock.child.findUnique.mockResolvedValue(null);
    const missing = await app.inject({
      method: "GET",
      url: `/v1/family/children/${CHILD_ID}`,
      headers: authHeader(app),
    });
    expect(missing.statusCode).toBe(404);
    await app.close();
  });

  it("returns 403 when accessing another family's child", async () => {
    const app = await buildApp(familyRoutes, "/v1/family");
    prismaMock.child.findUnique.mockResolvedValue({ id: CHILD_ID, familyId: "fam-2" });

    const res = await app.inject({
      method: "GET",
      url: `/v1/family/children/${CHILD_ID}`,
      headers: authHeader(app, "fam-1"),
    });
    expect(res.statusCode).toBe(403);
    await app.close();
  });

  it("returns 401 when no JWT is provided", async () => {
    const app = await buildApp(familyRoutes, "/v1/family");
    const res = await app.inject({ method: "GET", url: `/v1/family/children/${CHILD_ID}` });
    expect(res.statusCode).toBe(401);
    await app.close();
  });

  it("deletes a child with a full GDPR erasure cascade", async () => {
    const app = await buildApp(familyRoutes, "/v1/family");
    prismaMock.child.findUnique.mockResolvedValue({ id: CHILD_ID, familyId: "fam-1" });
    prismaMock.child.delete.mockResolvedValue({ id: CHILD_ID });

    const res = await app.inject({
      method: "DELETE",
      url: `/v1/family/children/${CHILD_ID}`,
      headers: authHeader(app),
    });
    expect(res.statusCode).toBe(200);
    const cascade = { where: { childId: CHILD_ID } };
    expect(prismaMock.device.deleteMany).toHaveBeenCalledWith(cascade);
    expect(prismaMock.ruleSet.deleteMany).toHaveBeenCalledWith(cascade);
    expect(prismaMock.locationPing.deleteMany).toHaveBeenCalledWith(cascade);
    expect(prismaMock.geofence.deleteMany).toHaveBeenCalledWith(cascade);
    expect(prismaMock.alert.deleteMany).toHaveBeenCalledWith(cascade);
    expect(prismaMock.consentRecord.deleteMany).toHaveBeenCalledWith(cascade);
    expect(prismaMock.child.delete).toHaveBeenCalledWith({ where: { id: CHILD_ID } });
    const txCalls = prismaMock.$transaction.mock.calls[0][0] as unknown[];
    expect(txCalls).toHaveLength(7);
    await app.close();
  });

  it("returns 404 from /me when the family no longer exists", async () => {
    const app = await buildApp(familyRoutes, "/v1/family");
    prismaMock.family.findUnique.mockResolvedValue(null);

    const res = await app.inject({ method: "GET", url: "/v1/family/me", headers: authHeader(app) });
    expect(res.statusCode).toBe(404);
    expect(res.json().error).toBe("family_not_found");
    await app.close();
  });

  it("rejects /me without a token (401) and with a device token (403)", async () => {
    const app = await buildApp(familyRoutes, "/v1/family");
    const unauthenticated = await app.inject({ method: "GET", url: "/v1/family/me" });
    expect(unauthenticated.statusCode).toBe(401);

    const device = await app.inject({ method: "GET", url: "/v1/family/me", headers: deviceHeader(app) });
    expect(device.statusCode).toBe(403);
    expect(device.json().error).toBe("parent_role_required");
    expect(prismaMock.family.findUnique).not.toHaveBeenCalled();
    await app.close();
  });

  it("rejects an invalid child body with 400", async () => {
    const app = await buildApp(familyRoutes, "/v1/family");
    const missing = await app.inject({
      method: "POST",
      url: "/v1/family/children",
      headers: authHeader(app),
      payload: { birthYear: 2013 },
    });
    expect(missing.statusCode).toBe(400);

    const futureBirthYear = await app.inject({
      method: "POST",
      url: "/v1/family/children",
      headers: authHeader(app),
      payload: { displayName: "Alex", birthYear: new Date().getFullYear() + 1 },
    });
    expect(futureBirthYear.statusCode).toBe(400);

    const badConsentMethod = await app.inject({
      method: "POST",
      url: "/v1/family/children",
      headers: authHeader(app),
      payload: { displayName: "Alex", birthYear: 2013, consent: { method: "smoke_signals", jurisdiction: "US" } },
    });
    expect(badConsentMethod.statusCode).toBe(400);
    expect(prismaMock.child.create).not.toHaveBeenCalled();
    await app.close();
  });

  it("returns 404 when creating a child for a family that no longer exists", async () => {
    const app = await buildApp(familyRoutes, "/v1/family");
    prismaMock.family.findUnique.mockResolvedValue(null);

    const res = await app.inject({
      method: "POST",
      url: "/v1/family/children",
      headers: authHeader(app),
      payload: { displayName: "Alex", birthYear: 2013 },
    });
    expect(res.statusCode).toBe(404);
    expect(res.json().error).toBe("family_not_found");
    expect(prismaMock.child.create).not.toHaveBeenCalled();
    await app.close();
  });

  it("updates a child's profile (200)", async () => {
    const app = await buildApp(familyRoutes, "/v1/family");
    prismaMock.child.findUnique.mockResolvedValue({ id: CHILD_ID, familyId: "fam-1" });
    prismaMock.child.update.mockResolvedValue({ id: CHILD_ID, displayName: "Alexandra", avatarUrl: null });

    const res = await app.inject({
      method: "PATCH",
      url: `/v1/family/children/${CHILD_ID}`,
      headers: authHeader(app),
      payload: { displayName: "Alexandra", avatarUrl: null },
    });
    expect(res.statusCode).toBe(200);
    expect(res.json().displayName).toBe("Alexandra");
    expect(prismaMock.child.update).toHaveBeenCalledWith({
      where: { id: CHILD_ID },
      data: { displayName: "Alexandra", avatarUrl: null },
    });
    await app.close();
  });

  it("rejects a bad child patch body (400) and a missing child (404)", async () => {
    const app = await buildApp(familyRoutes, "/v1/family");
    prismaMock.child.findUnique.mockResolvedValue({ id: CHILD_ID, familyId: "fam-1" });

    const emptyName = await app.inject({
      method: "PATCH",
      url: `/v1/family/children/${CHILD_ID}`,
      headers: authHeader(app),
      payload: { displayName: "" },
    });
    expect(emptyName.statusCode).toBe(400);

    const badYear = await app.inject({
      method: "PATCH",
      url: `/v1/family/children/${CHILD_ID}`,
      headers: authHeader(app),
      payload: { birthYear: 1899 },
    });
    expect(badYear.statusCode).toBe(400);
    expect(prismaMock.child.update).not.toHaveBeenCalled();

    prismaMock.child.findUnique.mockResolvedValue(null);
    const missing = await app.inject({
      method: "PATCH",
      url: `/v1/family/children/${CHILD_ID}`,
      headers: authHeader(app),
      payload: { displayName: "Alex" },
    });
    expect(missing.statusCode).toBe(404);
    await app.close();
  });

  it("records a consent event for an existing child (201)", async () => {
    const app = await buildApp(familyRoutes, "/v1/family");
    prismaMock.child.findUnique.mockResolvedValue({ id: CHILD_ID, familyId: "fam-1" });
    prismaMock.family.findUnique.mockResolvedValue(FAMILY);
    prismaMock.consentRecord.create.mockResolvedValue({ id: "consent-1", method: "kba", jurisdiction: "US" });

    const res = await app.inject({
      method: "POST",
      url: `/v1/family/children/${CHILD_ID}/consent`,
      headers: authHeader(app),
      payload: { method: "kba", jurisdiction: "US", thirdPartySharing: true },
    });
    expect(res.statusCode).toBe(201);
    expect(res.json().consent.id).toBe("consent-1");
    expect(prismaMock.consentRecord.create).toHaveBeenCalledWith(
      expect.objectContaining({
        data: expect.objectContaining({
          childId: CHILD_ID,
          parentId: "parent-1",
          method: "kba",
          jurisdiction: "US",
          thirdPartySharing: true,
        }),
      }),
    );
    await app.close();
  });

  it("rejects an invalid consent body (400)", async () => {
    const app = await buildApp(familyRoutes, "/v1/family");
    prismaMock.child.findUnique.mockResolvedValue({ id: CHILD_ID, familyId: "fam-1" });

    const res = await app.inject({
      method: "POST",
      url: `/v1/family/children/${CHILD_ID}/consent`,
      headers: authHeader(app),
      payload: { method: "pinky_swear", jurisdiction: "US" },
    });
    expect(res.statusCode).toBe(400);
    expect(prismaMock.consentRecord.create).not.toHaveBeenCalled();
    await app.close();
  });

  it("rejects consent whose jurisdiction does not match the family region (428)", async () => {
    const app = await buildApp(familyRoutes, "/v1/family");
    prismaMock.child.findUnique.mockResolvedValue({ id: CHILD_ID, familyId: "fam-1" });
    prismaMock.family.findUnique.mockResolvedValue(FAMILY); // region US

    const res = await app.inject({
      method: "POST",
      url: `/v1/family/children/${CHILD_ID}/consent`,
      headers: authHeader(app),
      payload: { method: "kba", jurisdiction: "EU" },
    });
    expect(res.statusCode).toBe(428);
    expect(res.json().error).toBe("consent_jurisdiction_mismatch");
    expect(prismaMock.consentRecord.create).not.toHaveBeenCalled();
    await app.close();
  });

  it("GET /export downloads the family archive without credential material", async () => {
    const app = await buildApp(familyRoutes, "/v1/family");
    prismaMock.family.findUnique.mockResolvedValue({
      id: FAMILY.id,
      name: "Demo",
      region: "US",
      parents: [
        {
          id: "parent-1",
          email: "demo@familyshield.dev",
          passwordHash: "argon2$secret",
          mfaSecret: "JBSWY3DPEHPK3PXP",
          mfaEnabled: true,
        },
      ],
      children: [
        { id: CHILD_ID, displayName: "Alex", devices: [], ruleSet: null, consents: [], geofences: [], alerts: [] },
      ],
    });

    const res = await app.inject({ method: "GET", url: "/v1/family/export", headers: authHeader(app) });
    expect(res.statusCode).toBe(200);
    expect(res.headers["content-disposition"]).toContain("attachment");
    expect(res.headers["content-disposition"]).toContain(`familyshield-export-${FAMILY.id}.json`);
    const body = res.json();
    expect(body.exportedAt).toBeTruthy();
    expect(body.family.children).toHaveLength(1);
    expect(body.family.parents).toHaveLength(1);
    expect(body.family.parents[0].email).toBe("demo@familyshield.dev");
    // Credential material must never leave the API — including in exports.
    const raw = JSON.stringify(body);
    expect(raw).not.toContain("passwordHash");
    expect(raw).not.toContain("mfaSecret");
    expect(raw).not.toContain("argon2$secret");
    expect(raw).not.toContain("JBSWY3DPEHPK3PXP");
    await app.close();
  });

  it("GET /export returns 404 when the family is missing", async () => {
    const app = await buildApp(familyRoutes, "/v1/family");
    prismaMock.family.findUnique.mockResolvedValue(null);

    const res = await app.inject({ method: "GET", url: "/v1/family/export", headers: authHeader(app) });
    expect(res.statusCode).toBe(404);
    expect(res.json().error).toBe("family_not_found");
    await app.close();
  });

  it("issue #31: GET /me returns accumulated daily screenTimeTodayMinutes from Redis", async () => {
    const app = await buildApp(familyRoutes, "/v1/family");
    prismaMock.family.findUnique.mockResolvedValue({
      id: FAMILY.id,
      name: "Demo",
      region: "US",
      parents: [{ id: "parent-1", email: "demo@familyshield.dev" }],
      children: [{ id: CHILD_ID, displayName: "Alex", devices: [], consents: [] }],
    });

    const today = new Date().toISOString().slice(0, 10);
    const redis = MockRedis.instances[MockRedis.instances.length - 1];
    redis.get.mockImplementation(async (key: string) => {
      if (key === `usage:child:${CHILD_ID}:${today}`) return "45";
      return null;
    });

    const res = await app.inject({ method: "GET", url: "/v1/family/me", headers: authHeader(app) });
    expect(res.statusCode).toBe(200);
    const body = res.json();
    expect(body.children[0].screenTimeTodayMinutes).toBe(45);
    await app.close();
  });
});

