import { beforeEach, describe, expect, it, vi } from "vitest";
import { createHmac } from "node:crypto";
import { signV2 } from "../src/lib/internalAuth.js";
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
        ...signV2(SECRET, raw, { caller: "ai-engine" }),
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

  /** Issue #225 bug 1: the receiver's alert and the worker retry share a dedupe key. */
  it("returns 200 and creates no second row for a duplicate dedupeKey", async () => {
    const app = await buildApp(alertsRoutes, "/v1/alerts");
    prismaMock.child.findUnique.mockResolvedValue(CHILD);
    const existing = { id: "a-admin-1", category: "tamper" };
    prismaMock.alert.findFirst
      .mockResolvedValueOnce(null) // first POST: key not seen
      .mockResolvedValueOnce(existing); // second POST: key already stored
    prismaMock.alert.create.mockResolvedValue(existing);

    const payload = {
      childId: CHILD.id,
      deviceId: "dev-1",
      severity: "critical",
      category: "tamper",
      title: "Device admin was removed",
      body: "b",
      dedupeKey: "dev-1|device_admin_removed|1700000000000",
    };
    const post = () => {
      const raw = JSON.stringify(payload);
      return app.inject({
        method: "POST",
        url: "/v1/alerts/internal",
        headers: { "content-type": "application/json", ...signV2(SECRET, raw, { caller: "ai-engine" }) },
        payload: raw,
      });
    };

    const first = await post();
    const retry = await post();

    expect(first.statusCode).toBe(201);
    expect(retry.statusCode).toBe(200);
    expect(retry.json().alert.id).toBe(existing.id);
    expect(prismaMock.alert.create).toHaveBeenCalledTimes(1);
    expect(prismaMock.alert.create).toHaveBeenCalledWith(
      expect.objectContaining({ data: expect.objectContaining({ dedupeKey: payload.dedupeKey }) }),
    );
    await app.close();
  });

  /** The two workers can race past the pre-check; the partial unique index must still answer 200. */
  it("treats a unique-index collision on dedupeKey as a successful retry", async () => {
    const app = await buildApp(alertsRoutes, "/v1/alerts");
    prismaMock.child.findUnique.mockResolvedValue(CHILD);
    const existing = { id: "a-admin-2", category: "tamper" };
    prismaMock.alert.findFirst
      .mockResolvedValueOnce(null) // both workers pass the pre-check
      .mockResolvedValueOnce(existing); // then lose the insert race and read the winner
    prismaMock.alert.create.mockRejectedValue(
      Object.assign(new Error("Unique constraint failed"), { code: "P2002" }),
    );

    const raw = JSON.stringify({
      childId: CHILD.id,
      deviceId: "dev-1",
      severity: "critical",
      category: "tamper",
      title: "Device admin was removed",
      body: "b",
      dedupeKey: "dev-1|device_admin_removed|1700000000001",
    });
    const res = await app.inject({
      method: "POST",
      url: "/v1/alerts/internal",
      headers: { "content-type": "application/json", ...signV2(SECRET, raw, { caller: "ai-engine" }) },
      payload: raw,
    });

    expect(res.statusCode).toBe(200);
    expect(res.json().alert.id).toBe(existing.id);
    expect(prismaMock.alert.create).toHaveBeenCalledTimes(1);
    await app.close();
  });

  /**
   * Issue #227: a repeated attempt inside the same 5-minute window is not a second alert. The
   * repeat carries the aggregate count and updates the row that already exists; the parent is not
   * pushed again. This is deliberately not the #225 rule — that key names one event, this key names
   * one window whose count grows.
   */
  it("updates the existing row's attempt count instead of creating a second row", async () => {
    const app = await buildApp(alertsRoutes, "/v1/alerts");
    prismaMock.child.findUnique.mockResolvedValue(CHILD);
    const firstRow = { id: "a-guard-1", category: "tamper", attemptCount: 1, body: "opened" };
    const updated = { ...firstRow, attemptCount: 2, body: "2 attempts" };
    prismaMock.alert.findFirst
      .mockResolvedValueOnce(null) // attempt 1: the window's first alert
      .mockResolvedValueOnce(firstRow); // attempt 2: same window, new count
    prismaMock.alert.create.mockResolvedValue(firstRow);
    prismaMock.alert.updateMany.mockResolvedValue({ count: 1 });
    prismaMock.alert.findUnique.mockResolvedValue(updated);

    const payload = {
      childId: CHILD.id,
      deviceId: "dev-1",
      severity: "critical",
      category: "tamper",
      title: "Someone tried to remove protection",
      body: "opened",
      dedupeKey: "dev-1|protection_screen_opened|1700000000000",
      attemptCount: 1,
    };
    const post = (attemptCount: number, body: string) => {
      const raw = JSON.stringify({ ...payload, attemptCount, body });
      return app.inject({
        method: "POST",
        url: "/v1/alerts/internal",
        headers: { "content-type": "application/json", ...signV2(SECRET, raw, { caller: "ai-engine" }) },
        payload: raw,
      });
    };

    const first = await post(1, "opened");
    const repeat = await post(2, "2 attempts");

    expect(first.statusCode).toBe(201);
    expect(repeat.statusCode).toBe(200);
    expect(prismaMock.alert.create).toHaveBeenCalledTimes(1);
    expect(prismaMock.alert.update).not.toHaveBeenCalled();
    expect(prismaMock.alert.updateMany).toHaveBeenCalledTimes(1);
    expect(prismaMock.alert.updateMany).toHaveBeenCalledWith({
      where: { id: firstRow.id, attemptCount: { lt: 2 } },
      data: expect.objectContaining({ attemptCount: 2, body: "2 attempts" }),
    });
    expect(repeat.json().alert.attemptCount).toBe(2);
    // An aggregate update is not a new page: push fan-out must not run a second time.
    expect(prismaMock.parentPushToken.findMany).not.toHaveBeenCalled();
    await app.close();
  });

  it("a new window creates a new row even when the previous window is still open", async () => {
    const app = await buildApp(alertsRoutes, "/v1/alerts");
    prismaMock.child.findUnique.mockResolvedValue(CHILD);
    prismaMock.alert.findFirst.mockResolvedValue(null); // a different window key was never seen
    prismaMock.alert.create.mockResolvedValue({ id: "a-guard-2", attemptCount: 2 });

    const raw = JSON.stringify({
      childId: CHILD.id,
      deviceId: "dev-1",
      severity: "critical",
      category: "tamper",
      title: "Someone tried to remove protection",
      body: "opened",
      dedupeKey: "dev-1|protection_screen_opened|1700000300000",
      attemptCount: 1,
    });
    const res = await app.inject({
      method: "POST",
      url: "/v1/alerts/internal",
      headers: { "content-type": "application/json", ...signV2(SECRET, raw, { caller: "ai-engine" }) },
      payload: raw,
    });

    expect(res.statusCode).toBe(201);
    expect(prismaMock.alert.create).toHaveBeenCalledWith(
      expect.objectContaining({ data: expect.objectContaining({ attemptCount: 1 }) }),
    );
    await app.close();
  });

  it("an out-of-order lower count does not lower the stored count", async () => {
    const app = await buildApp(alertsRoutes, "/v1/alerts");
    prismaMock.child.findUnique.mockResolvedValue(CHILD);
    const existing = { id: "a-guard-3", category: "tamper", attemptCount: 5, body: "5 attempts" };
    prismaMock.alert.findFirst.mockResolvedValue(existing);

    const raw = JSON.stringify({
      childId: CHILD.id,
      deviceId: "dev-1",
      severity: "critical",
      category: "tamper",
      title: "Someone tried to remove protection",
      body: "3 attempts",
      dedupeKey: "dev-1|protection_screen_opened|1700000000000",
      attemptCount: 3,
    });
    const res = await app.inject({
      method: "POST",
      url: "/v1/alerts/internal",
      headers: { "content-type": "application/json", ...signV2(SECRET, raw, { caller: "ai-engine" }) },
      payload: raw,
    });

    expect(res.statusCode).toBe(200);
    expect(res.json().alert.attemptCount).toBe(5);
    expect(prismaMock.alert.updateMany).not.toHaveBeenCalled();
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
      headers: { "content-type": "application/json", ...signV2(SECRET, raw, { caller: "ai-engine" }) },
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
      headers: { "content-type": "application/json", ...signV2(SECRET, raw, { caller: "ai-engine" }) },
      payload: raw,
    });
    expect(res.statusCode).toBe(404);
    expect(res.json().error).toBe("child_not_found");
    expect(prismaMock.alert.create).not.toHaveBeenCalled();
    await app.close();
  });
});
