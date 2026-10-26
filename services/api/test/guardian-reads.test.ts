import { beforeEach, describe, expect, it, vi } from "vitest";
import { alertsRoutes } from "../src/routes/alerts.js";
import { contentRoutes } from "../src/routes/content.js";
import { locationRoutes } from "../src/routes/location.js";
import { socialRoutes } from "../src/routes/social.js";
import { familyRoutes } from "../src/routes/family.js";
import { reportsRoutes } from "../src/routes/reports.js";
import { deviceRoutes } from "../src/routes/devices.js";
import { MockRedis, authHeader, buildApp, prismaMock, resetPrismaMock } from "./helpers.js";

vi.mock("../src/db.js", async () => {
  const { prismaMock } = await import("./helpers.js");
  return { prisma: prismaMock };
});
vi.mock("ioredis", async () => {
  const { MockRedis } = await import("./helpers.js");
  return { Redis: MockRedis };
});
// The summary route withholds one key from a real summariser result; mocking the summariser keeps the
// row about the withholding rather than about six aggregate queries.
vi.mock("../src/lib/activitySummary.js", () => ({
  summarizeChildActivity: async () => ({
    appMinutes: [{ packageId: "com.a", minutes: 12 }],
    topBlockedDomains: [{ domain: "example.com", count: 3 }],
    calls: 1,
    sms: 2,
  }),
}));

/**
 * ADR-0014 amendment of 2026-10-26 (roadmap 2.7): for a guardian, a read needs the permission its
 * invite granted; owners and co-parents are unchanged; a device token is untouched.
 *
 * Every row here is the tree the amendment's "proof owed" list names — owner 200, co-parent with no
 * permissions 200, guardian with the permission 200, guardian without it `403 permission_required` —
 * plus the embedded-field half (decision 2) and the push fan-out (decision 3).
 */

/** The `Parent` row `loadParentRole` reads for the signed-in parent. */
function caller(role: string, permissions: string[] = []) {
  prismaMock.parent.findUnique.mockResolvedValue({ id: "parent-1", role, permissions, familyId: "fam-1" });
}

describe("guardian reads (ADR-0014 amendment)", () => {
  beforeEach(() => {
    resetPrismaMock();
    void MockRedis;
  });

  describe("GET /v1/alerts needs `alerts`", () => {
    const list = () => {
      prismaMock.alert.count.mockResolvedValue(0);
      prismaMock.alert.findMany.mockResolvedValue([]);
    };

    it("lets a guardian with `alerts` through", async () => {
      const app = await buildApp(alertsRoutes, "/v1/alerts");
      caller("guardian", ["alerts"]);
      list();

      const res = await app.inject({ method: "GET", url: "/v1/alerts", headers: authHeader(app) });
      expect(res.statusCode).toBe(200);
      await app.close();
    });

    it("refuses a guardian without `alerts`, naming the permission", async () => {
      const app = await buildApp(alertsRoutes, "/v1/alerts");
      caller("guardian", []);
      list();

      const res = await app.inject({ method: "GET", url: "/v1/alerts", headers: authHeader(app) });
      expect(res.statusCode).toBe(403);
      expect(res.json()).toEqual({ error: "permission_required", permission: "alerts" });
      await app.close();
    });

    it("lets a co-parent with no permissions through — decision 1 leaves that role unchanged", async () => {
      const app = await buildApp(alertsRoutes, "/v1/alerts");
      caller("co-parent", []);
      list();

      const res = await app.inject({ method: "GET", url: "/v1/alerts", headers: authHeader(app) });
      expect(res.statusCode).toBe(200);
      await app.close();
    });

    it("lets the owner through", async () => {
      const app = await buildApp(alertsRoutes, "/v1/alerts");
      caller("owner", []);
      list();

      const res = await app.inject({ method: "GET", url: "/v1/alerts", headers: authHeader(app) });
      expect(res.statusCode).toBe(200);
      await app.close();
    });
  });

  describe("every other gated read refuses a guardian the same way", () => {
    const cases: Array<{ name: string; build: () => Promise<any>; url: string; permission: string }> = [
      { name: "GET /v1/location/:childId/latest needs `location`", build: () => buildApp(locationRoutes, "/v1/location"), url: "/v1/location/child-1/latest", permission: "location" },
      { name: "GET /v1/social/events needs `social`", build: () => buildApp(socialRoutes, "/v1/social"), url: "/v1/social/events?childId=child-1", permission: "social" },
      { name: "GET /v1/content/searches needs `social`", build: () => buildApp(contentRoutes, "/v1/content"), url: "/v1/content/searches?childId=child-1", permission: "social" },
      { name: "GET /v1/reports/web needs `social`", build: () => buildApp(reportsRoutes, "/v1/reports"), url: "/v1/reports/web?childId=child-1", permission: "social" },
      { name: "GET /v1/reports/activity needs `social`", build: () => buildApp(reportsRoutes, "/v1/reports"), url: "/v1/reports/activity?childId=child-1", permission: "social" },
    ];

    for (const c of cases) {
      it(`${c.name} — a guardian without it is 403`, async () => {
        const app = await c.build();
        caller("guardian", []);
        prismaMock.child.findUnique.mockResolvedValue({ id: "child-1", familyId: "fam-1" });
        const res = await app.inject({ method: "GET", url: c.url, headers: authHeader(app) });
        expect(res.statusCode).toBe(403);
        expect(res.json()).toEqual({ error: "permission_required", permission: c.permission });
        await app.close();
      });

      it(`${c.name} — a co-parent with no permissions is 200`, async () => {
        const app = await c.build();
        caller("co-parent", []);
        prismaMock.child.findUnique.mockResolvedValue({ id: "child-1", familyId: "fam-1" });
        const res = await app.inject({ method: "GET", url: c.url, headers: authHeader(app) });
        expect(res.statusCode).not.toBe(403);
        await app.close();
      });
    }
  });

  describe("GET /v1/family/me withholds what a narrow read refuses (decision 2)", () => {
    const family = () => {
      prismaMock.family.findUnique.mockResolvedValue({
        id: "fam-1",
        name: "Family",
        region: "US",
        createdAt: new Date(),
        timezone: "UTC",
        timezoneSource: "default",
        parents: [{ id: "parent-1", email: "p@example.com", displayName: "P", role: "guardian", permissions: [], mfaEnabled: false }],
        children: [
          {
            id: "child-1",
            familyId: "fam-1",
            displayName: "Alex",
            birthYear: 2015,
            devices: [],
            ruleSet: null,
            consents: [],
            geofences: [{ id: "g1", label: "Home", lat: 1, lng: 2, radiusM: 100 }],
          },
        ],
      });
    };

    it("omits geofences for a guardian without `location`", async () => {
      const app = await buildApp(familyRoutes, "/v1/family");
      caller("guardian", []);
      family();

      const res = await app.inject({ method: "GET", url: "/v1/family/me", headers: authHeader(app) });
      expect(res.statusCode).toBe(200);
      const body = res.json();
      expect(body.children[0]).not.toHaveProperty("geofences");
      expect(body.family.children[0]).not.toHaveProperty("geofences");
      await app.close();
    });

    it("keeps geofences for a guardian with `location`", async () => {
      const app = await buildApp(familyRoutes, "/v1/family");
      caller("guardian", ["location"]);
      family();

      const res = await app.inject({ method: "GET", url: "/v1/family/me", headers: authHeader(app) });
      expect(res.statusCode).toBe(200);
      expect(res.json().children[0]).toHaveProperty("geofences");
      await app.close();
    });

    it("keeps geofences for a co-parent with no permissions", async () => {
      const app = await buildApp(familyRoutes, "/v1/family");
      caller("co-parent", []);
      family();

      const res = await app.inject({ method: "GET", url: "/v1/family/me", headers: authHeader(app) });
      expect(res.statusCode).toBe(200);
      expect(res.json().children[0]).toHaveProperty("geofences");
      await app.close();
    });
  });

  describe("GET /v1/reports/summary withholds domain names, not counts (decision 5)", () => {
    it("has no topBlockedDomains for a guardian without `social`, and keeps the rest", async () => {
      const app = await buildApp(reportsRoutes, "/v1/reports");
      caller("guardian", []);
      prismaMock.child.findUnique.mockResolvedValue({ id: "child-1", familyId: "fam-1" });

      const res = await app.inject({ method: "GET", url: "/v1/reports/summary?childId=child-1", headers: authHeader(app) });
      expect(res.statusCode).toBe(200);
      const body = res.json();
      expect(body).not.toHaveProperty("topBlockedDomains");
      expect(body.appMinutes).toBeDefined();
      expect(body.calls).toBe(1);
      await app.close();
    });

    it("keeps topBlockedDomains for a guardian with `social`", async () => {
      const app = await buildApp(reportsRoutes, "/v1/reports");
      caller("guardian", ["social"]);
      prismaMock.child.findUnique.mockResolvedValue({ id: "child-1", familyId: "fam-1" });

      const res = await app.inject({ method: "GET", url: "/v1/reports/summary?childId=child-1", headers: authHeader(app) });
      expect(res.statusCode).toBe(200);
      expect(res.json().topBlockedDomains).toEqual([{ domain: "example.com", count: 3 }]);
      await app.close();
    });
  });

  describe("GET /v1/devices/:id withholds `urls` (decision 2)", () => {
    const device = () => {
      prismaMock.device.findUnique.mockResolvedValue({
        id: "dev-1",
        childId: "child-1",
        familyId: "fam-1",
        platform: "android",
        model: "Pixel",
        osVersion: "14",
        status: "online",
        batteryPct: 50,
        lastSeen: new Date(),
      });
    };

    it("drops urls for a guardian without `social`", async () => {
      const app = await buildApp(deviceRoutes, "/v1/devices");
      caller("guardian", []);
      device();
      const app0 = app;
      const redis = MockRedis.instances[MockRedis.instances.length - 1];
      redis.get.mockImplementation(async (key: string) =>
        key === "device:dev-1:telemetry" ? JSON.stringify({ batteryPct: 50, urls: ["https://example.com"] }) : null,
      );
      void app0;

      const res = await app.inject({ method: "GET", url: "/v1/devices/dev-1", headers: authHeader(app) });
      expect(res.statusCode).toBe(200);
      const telemetry = res.json().telemetry ?? {};
      expect(telemetry).not.toHaveProperty("urls");
      await app.close();
    });
  });

  describe("the push fan-out skips a guardian without `alerts` (decision 3)", () => {
    it("asks the database for parents that are not gated guardians", async () => {
      const { notifyParentsOfAlert, setPushProviders } = await import("../src/lib/push/notify.js");
      setPushProviders([
        { platform: "android", canWakeDevices: false, send: async () => ({ ok: true }) },
      ] as never);
      prismaMock.digestPrefs.findUnique.mockResolvedValue(null);
      prismaMock.parent.findMany.mockResolvedValue([]);

      await notifyParentsOfAlert("fam-1", { id: "a1", severity: "critical", category: "sos", title: "t", body: "b" } as never);

      expect(prismaMock.parent.findMany).toHaveBeenCalledWith(
        expect.objectContaining({
          where: expect.objectContaining({
            OR: [{ role: { not: "guardian" } }, { role: "guardian", permissions: { has: "alerts" } }],
          }),
        }),
      );
    });
  });
});
