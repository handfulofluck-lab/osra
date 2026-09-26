import { beforeEach, describe, expect, it, vi } from "vitest";
import { createHmac } from "node:crypto";
import { alertsRoutes } from "../src/routes/alerts.js";
import { MockRedis, authHeader, buildApp, deviceHeader, prismaMock, resetPrismaMock } from "./helpers.js";

vi.mock("../src/db.js", async () => {
  const { prismaMock } = await import("./helpers.js");
  return { prisma: prismaMock };
});
vi.mock("ioredis", async () => {
  const { MockRedis } = await import("./helpers.js");
  return { Redis: MockRedis };
});

const SECRET = "test-internal-secret";
const CHILD = { id: "child-1", familyId: "fam-1" };

const sign = (raw: string) => createHmac("sha256", SECRET).update(raw).digest("hex");

describe("alerts routes", () => {
  beforeEach(() => {
    resetPrismaMock();
    process.env.INTERNAL_HMAC_SECRET = SECRET;
  });

  it("lists alerts in the {items, meta} envelope scoped to the family", async () => {
    const app = await buildApp(alertsRoutes, "/v1/alerts");
    prismaMock.alert.count.mockResolvedValue(7);
    prismaMock.alert.findMany.mockResolvedValue([{ id: "a1" }, { id: "a2" }]);

    const res = await app.inject({ method: "GET", url: "/v1/alerts?page=1&limit=2", headers: authHeader(app) });
    expect(res.statusCode).toBe(200);
    const body = res.json();
    expect(body.items).toHaveLength(2);
    expect(body.meta).toEqual({ total: 7, page: 1, limit: 2 });
    await app.close();
  });

  it("rejects an internal alert without a valid HMAC signature (401)", async () => {
    const app = await buildApp(alertsRoutes, "/v1/alerts");
    prismaMock.child.findUnique.mockResolvedValue(CHILD);

    const res = await app.inject({
      method: "POST",
      url: "/v1/alerts/internal",
      headers: { "x-familyshield-signature": "deadbeef" },
      payload: { childId: CHILD.id, severity: "info", category: "sos", title: "t", body: "b" },
    });
    expect(res.statusCode).toBe(401);
    expect(prismaMock.alert.create).not.toHaveBeenCalled();
    await app.close();
  });

  it("persists and publishes a validly-signed internal alert (201)", async () => {
    const app = await buildApp(alertsRoutes, "/v1/alerts");
    prismaMock.child.findUnique.mockResolvedValue(CHILD);
    prismaMock.alert.create.mockResolvedValue({ id: "a-new", category: "grooming" });

    const raw = JSON.stringify({ childId: CHILD.id, deviceId: "dev-1", severity: "critical", category: "grooming", title: "t", body: "b", metadata: { src: "ai" } });
    const res = await app.inject({
      method: "POST",
      url: "/v1/alerts/internal",
      headers: {
        "content-type": "application/json",
        "x-familyshield-signature": sign(raw),
      },
      payload: raw,
    });
    expect(res.statusCode).toBe(201);
    expect(prismaMock.alert.create).toHaveBeenCalledWith(
      expect.objectContaining({
        data: expect.objectContaining({ childId: CHILD.id, category: "grooming" }),
      }),
    );
    // The alert must be published on the family's realtime channel.
    const publishes = MockRedis.instances.flatMap((r) => r.publish.mock.calls);
    expect(publishes.some(([channel, msg]) =>
      channel === "family:fam-1:events" && JSON.parse(msg as string).type === "alert",
    )).toBe(true);
    await app.close();
  });

  it("acknowledges an alert", async () => {
    const app = await buildApp(alertsRoutes, "/v1/alerts");
    prismaMock.alert.findUnique.mockResolvedValue({ id: "a1", child: { familyId: "fam-1" } });
    prismaMock.alert.update.mockResolvedValue({ id: "a1", acknowledged: true });

    const res = await app.inject({
      method: "POST",
      url: "/v1/alerts/a1/ack",
      headers: authHeader(app),
    });
    expect(res.statusCode).toBe(200);
    expect(res.json().alert.acknowledged).toBe(true);
    await app.close();
  });

  it("applies pagination math: page 3 with limit 20 skips 40 rows", async () => {
    const app = await buildApp(alertsRoutes, "/v1/alerts");
    prismaMock.alert.count.mockResolvedValue(100);
    prismaMock.alert.findMany.mockResolvedValue([]);

    const res = await app.inject({
      method: "GET",
      url: "/v1/alerts?page=3&limit=20",
      headers: authHeader(app),
    });
    expect(res.statusCode).toBe(200);
    expect(prismaMock.alert.findMany).toHaveBeenCalledWith(
      expect.objectContaining({ skip: 40, take: 20, orderBy: { createdAt: "desc" } }),
    );
    expect(res.json().meta).toEqual({ total: 100, page: 3, limit: 20 });
    await app.close();
  });

  it("defaults pagination to page 1 / limit 20 when params are absent", async () => {
    const app = await buildApp(alertsRoutes, "/v1/alerts");
    prismaMock.alert.count.mockResolvedValue(0);
    prismaMock.alert.findMany.mockResolvedValue([]);

    const res = await app.inject({ method: "GET", url: "/v1/alerts", headers: authHeader(app) });
    expect(res.statusCode).toBe(200);
    expect(prismaMock.alert.findMany).toHaveBeenCalledWith(expect.objectContaining({ skip: 0, take: 20 }));
    expect(res.json().meta).toEqual({ total: 0, page: 1, limit: 20 });
    await app.close();
  });

  it("rejects out-of-range pagination and unknown enum filters with 400 (not 500)", async () => {
    const app = await buildApp(alertsRoutes, "/v1/alerts");
    for (const query of ["page=0", "page=-2", "page=abc", "limit=0", "limit=101", "limit=many", "severity=bogus"]) {
      const res = await app.inject({ method: "GET", url: `/v1/alerts?${query}`, headers: authHeader(app) });
      expect(res.statusCode).toBe(400);
    }
    expect(prismaMock.alert.findMany).not.toHaveBeenCalled();
    await app.close();
  });

  it("passes childId/severity/category filters into the query, always family-scoped", async () => {
    const app = await buildApp(alertsRoutes, "/v1/alerts");
    prismaMock.alert.count.mockResolvedValue(1);
    prismaMock.alert.findMany.mockResolvedValue([{ id: "a1" }]);

    const res = await app.inject({
      method: "GET",
      url: "/v1/alerts?childId=child-1&severity=critical&category=sos",
      headers: authHeader(app),
    });
    expect(res.statusCode).toBe(200);
    const expectedWhere = { child: { familyId: "fam-1" }, childId: "child-1", severity: "critical", category: "sos" };
    expect(prismaMock.alert.count).toHaveBeenCalledWith({ where: expectedWhere });
    expect(prismaMock.alert.findMany).toHaveBeenCalledWith(expect.objectContaining({ where: expectedWhere }));
    await app.close();
  });

  it("requires a parent JWT for listing (401 without one, 403 for device tokens)", async () => {
    const app = await buildApp(alertsRoutes, "/v1/alerts");
    const unauthenticated = await app.inject({ method: "GET", url: "/v1/alerts" });
    expect(unauthenticated.statusCode).toBe(401);

    const device = await app.inject({ method: "GET", url: "/v1/alerts", headers: deviceHeader(app) });
    expect(device.statusCode).toBe(403);
    expect(device.json().error).toBe("parent_role_required");
    expect(prismaMock.alert.findMany).not.toHaveBeenCalled();
    await app.close();
  });

  it("returns 404 when acknowledging a missing alert and 403 for another family's", async () => {
    const app = await buildApp(alertsRoutes, "/v1/alerts");
    prismaMock.alert.findUnique.mockResolvedValue(null);
    const missing = await app.inject({ method: "POST", url: "/v1/alerts/a9/ack", headers: authHeader(app) });
    expect(missing.statusCode).toBe(404);

    prismaMock.alert.findUnique.mockResolvedValue({ id: "a1", child: { familyId: "fam-2" } });
    const foreign = await app.inject({ method: "POST", url: "/v1/alerts/a1/ack", headers: authHeader(app, "fam-1") });
    expect(foreign.statusCode).toBe(403);
    expect(prismaMock.alert.update).not.toHaveBeenCalled();
    await app.close();
  });

  it("rejects a well-signed internal alert with an invalid payload (400)", async () => {
    const app = await buildApp(alertsRoutes, "/v1/alerts");
    const raw = JSON.stringify({ childId: CHILD.id, severity: "info", category: "nonsense", title: "t", body: "b" });
    const res = await app.inject({
      method: "POST",
      url: "/v1/alerts/internal",
      headers: { "content-type": "application/json", "x-familyshield-signature": sign(raw) },
      payload: raw,
    });
    expect(res.statusCode).toBe(400);
    expect(prismaMock.alert.create).not.toHaveBeenCalled();
    await app.close();
  });

  it("returns 404 for a well-signed internal alert naming an unknown child", async () => {
    const app = await buildApp(alertsRoutes, "/v1/alerts");
    prismaMock.child.findUnique.mockResolvedValue(null);

    const raw = JSON.stringify({ childId: "child-9", severity: "info", category: "sos", title: "t", body: "b" });
    const res = await app.inject({
      method: "POST",
      url: "/v1/alerts/internal",
      headers: { "content-type": "application/json", "x-familyshield-signature": sign(raw) },
      payload: raw,
    });
    expect(res.statusCode).toBe(404);
    expect(res.json().error).toBe("child_not_found");
    expect(prismaMock.alert.create).not.toHaveBeenCalled();
    await app.close();
  });
});
