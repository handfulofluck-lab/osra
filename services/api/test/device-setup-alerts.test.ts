import { randomBytes } from "node:crypto";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { PushProvider } from "../src/lib/push/types.js";
import { setPushProviders } from "../src/lib/push/notify.js";
import { signV2 } from "../src/lib/internalAuth.js";
import { alertsRoutes } from "../src/routes/alerts.js";
import { familyRoutes } from "../src/routes/family.js";
import { authHeader, buildApp, MockRedis, prismaMock, resetPrismaMock } from "./helpers.js";

vi.mock("../src/db.js", async () => ({ prisma: (await import("./helpers.js")).prismaMock }));
vi.mock("ioredis", async () => ({ Redis: (await import("./helpers.js")).MockRedis }));

const CHILD = { id: "child-1", familyId: "fam-1" };
const SECRET = randomBytes(32).toString("hex");
const START = new Date("2026-11-26T01:00:00.000Z");
const ALL_REQUIRED = {
  accessibility: "granted",
  usage_access: "granted",
  overlay: "granted",
  device_admin: "granted",
  web_filter: "granted",
  location: "granted",
  private_dns: "granted",
} as const;

function device(overrides: Record<string, unknown> = {}) {
  return {
    id: "dev-1",
    childId: CHILD.id,
    platform: "android",
    internalSecret: SECRET,
    pairedAt: START,
    setupCompletedAt: null,
    capabilities: {
      client: { app: "child-android", version: "0.2.0", build: 42, flavour: "full" },
      grants: { ...ALL_REQUIRED, accessibility: "missing" },
      features: {},
    },
    ...overrides,
  };
}

function signed(payload: Record<string, unknown>) {
  const raw = JSON.stringify(payload);
  return { raw, headers: { "content-type": "application/json", ...signV2(SECRET, raw) } };
}

function tamper(type = "accessibility_off") {
  return {
    childId: CHILD.id,
    deviceId: "dev-1",
    severity: "critical",
    category: "tamper",
    title: "Protection changed",
    body: "Synthetic setup event",
    metadata: { type },
    dedupeKey: `setup-test|${type}`,
  };
}

describe("initial-setup alert holding (#1127)", () => {
  const send = vi.fn(async () => ({ ok: true }));
  const provider: PushProvider = { platform: "android", send };

  beforeEach(() => {
    resetPrismaMock();
    setPushProviders([provider]);
    send.mockClear();
    for (const redis of MockRedis.instances) redis.publish.mockClear();
    prismaMock.child.findUnique.mockResolvedValue(CHILD);
    prismaMock.device.findUnique.mockResolvedValue(device());
    prismaMock.digestPrefs.findUnique.mockResolvedValue({ familyId: "fam-1", pushEnabled: true });
    prismaMock.parent.findMany.mockResolvedValue([{ id: "parent-1" }]);
    prismaMock.parentPushToken.findMany.mockResolvedValue([{ id: "token-1", parentId: "parent-1", platform: "android", token: "token" }]);
    prismaMock.alert.create.mockImplementation(async ({ data }) => ({ id: "alert-created", ...data }));
  });

  afterEach(() => {
    setPushProviders(null);
  });

  it("persists a grant-matched setup tamper without realtime or push, then dedupes quietly", async () => {
    const app = await buildApp(alertsRoutes, "/v1/alerts");
    const { raw, headers } = signed(tamper());
    const first = await app.inject({ method: "POST", url: "/v1/alerts/internal", headers, payload: raw });
    expect(first.statusCode).toBe(201);
    expect(prismaMock.alert.create).toHaveBeenCalledWith({
      data: expect.objectContaining({ category: "tamper", heldDuringSetup: true }),
    });
    expect(send).not.toHaveBeenCalled();
    expect(MockRedis.instances.flatMap((redis) => redis.publish.mock.calls)).toHaveLength(0);

    prismaMock.alert.findFirst.mockResolvedValue({ id: "held-existing", category: "tamper", heldDuringSetup: true, attemptCount: 1 });
    const retry = await app.inject({ method: "POST", url: "/v1/alerts/internal", headers: signed(tamper()).headers, payload: raw });
    expect(retry.statusCode).toBe(200);
    expect(prismaMock.alert.create).toHaveBeenCalledTimes(1);
    expect(send).not.toHaveBeenCalled();
    expect(MockRedis.instances.flatMap((redis) => redis.publish.mock.calls)).toHaveLength(0);
    await app.close();
  });

  it("keeps SOS and unrelated tamper events visible", async () => {
    const app = await buildApp(alertsRoutes, "/v1/alerts");
    for (const [category, type] of [["sos", "accessibility_off"], ["tamper", "private_dns_bypass"], ["tamper", "protection_screen_opened"]] as const) {
      const { raw, headers } = signed(tamper(type).childId ? { ...tamper(type), category } : {});
      const response = await app.inject({ method: "POST", url: "/v1/alerts/internal", headers, payload: raw });
      expect(response.statusCode).toBe(201);
    }
    expect(prismaMock.alert.create).toHaveBeenCalledTimes(3);
    for (const call of prismaMock.alert.create.mock.calls) {
      expect(call[0]).toEqual({ data: expect.objectContaining({ heldDuringSetup: false }) });
    }
    expect(send).toHaveBeenCalledTimes(3);
    await app.close();
  });

  it("excludes held rows from parent list count and items", async () => {
    const app = await buildApp(alertsRoutes, "/v1/alerts");
    prismaMock.alert.count.mockResolvedValue(0);
    prismaMock.alert.findMany.mockResolvedValue([]);
    const response = await app.inject({ method: "GET", url: "/v1/alerts", headers: authHeader(app) });
    expect(response.statusCode).toBe(200);
    const where = { child: { familyId: "fam-1" }, heldDuringSetup: false };
    expect(prismaMock.alert.count).toHaveBeenCalledWith({ where });
    expect(prismaMock.alert.findMany).toHaveBeenCalledWith(expect.objectContaining({ where }));
    await app.close();
  });

  it("does not acknowledge or return a held alert by id", async () => {
    const app = await buildApp(alertsRoutes, "/v1/alerts");
    prismaMock.alert.findUnique.mockResolvedValue({ id: "held-1", childId: CHILD.id, child: CHILD, heldDuringSetup: true });
    const response = await app.inject({ method: "POST", url: "/v1/alerts/held-1/ack", headers: authHeader(app) });
    expect(response.statusCode).toBe(404);
    expect(prismaMock.alert.update).not.toHaveBeenCalled();
    await app.close();
  });

  it("excludes held rows from the owner family export query", async () => {
    const app = await buildApp(familyRoutes, "/v1/family");
    prismaMock.family.findUnique.mockResolvedValue({ id: "fam-1", parents: [], children: [] });
    const response = await app.inject({ method: "GET", url: "/v1/family/export", headers: authHeader(app) });
    expect(response.statusCode).toBe(200);
    expect(prismaMock.family.findUnique).toHaveBeenCalledWith(expect.objectContaining({
      include: expect.objectContaining({
        children: expect.objectContaining({
          include: expect.objectContaining({ alerts: { where: { heldDuringSetup: false } } }),
        }),
      }),
    }));
    await app.close();
  });
});
