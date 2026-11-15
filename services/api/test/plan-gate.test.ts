import { beforeEach, describe, expect, it, vi } from "vitest";
import { authHeader, buildApp, prismaMock, resetPrismaMock } from "./helpers.js";

vi.mock("../src/db.js", () => ({ prisma: prismaMock }));

import { hasEnforcingPlan, nextEnforcementAt, PREMIUM_FEATURES, requirePlan } from "../src/lib/planGate.js";

const purchase = (overrides: Record<string, unknown> = {}) => ({
  familyId: "fam-1",
  source: "google_play",
  productId: "family.monthly",
  storeRefHash: "a".repeat(64),
  status: "active",
  expiresAt: new Date("2026-12-01T00:00:00.000Z"),
  autoRenews: true,
  lastVerifiedAt: new Date("2026-11-14T19:00:00.000Z"),
  cause: "verify",
  ...overrides,
});

beforeEach(() => {
  resetPrismaMock();
  prismaMock.family.findUnique.mockResolvedValue({ id: "fam-1", timezone: "Asia/Dubai" });
});

describe("family-local enforcement time", () => {
  it("moves a 23:00 Dubai refund at the following local 10:00, not immediately", () => {
    expect(nextEnforcementAt(new Date("2026-11-14T19:00:00.000Z"), "Asia/Dubai").toISOString()).toBe("2026-11-15T06:00:00.000Z");
  });

  it("uses the offset in force at 10:00 across DST changes", () => {
    expect(nextEnforcementAt(new Date("2026-03-08T04:00:00.000Z"), "America/New_York").toISOString()).toBe("2026-03-08T14:00:00.000Z");
    expect(nextEnforcementAt(new Date("2026-11-01T03:00:00.000Z"), "America/New_York").toISOString()).toBe("2026-11-01T15:00:00.000Z");
  });

  it("keeps a just-refunded plan enforceable before 10:00 and refuses it at 10:00", async () => {
    prismaMock.familyPurchase.findMany.mockResolvedValue([purchase({ status: "refunded", expiresAt: null })]);
    expect(await hasEnforcingPlan("fam-1", new Date("2026-11-15T05:59:59.000Z"))).toBe(true);
    expect(await hasEnforcingPlan("fam-1", new Date("2026-11-15T06:00:00.000Z"))).toBe(false);
  });

  it("does not gate grace or hold after expiry, but a missing expiry never buys time", async () => {
    prismaMock.familyPurchase.findMany.mockResolvedValue([purchase({ status: "on_hold", expiresAt: new Date("2026-11-01T00:00:00.000Z") })]);
    expect(await hasEnforcingPlan("fam-1", new Date("2026-11-15T12:00:00.000Z"))).toBe(true);
    prismaMock.familyPurchase.findMany.mockResolvedValue([purchase({ expiresAt: null })]);
    expect(await hasEnforcingPlan("fam-1", new Date("2026-11-15T12:00:00.000Z"))).toBe(false);
  });
});

describe("requirePlan", () => {
  async function fixture(now: Date) {
    const { requireParent } = await import("../src/middleware/requireFamily.js");
    return buildApp(async (app) => {
      app.post("/protected", { preHandler: [requireParent, requirePlan(() => now)] }, async () => ({ ok: true }));
    }, "");
  }

  it("answers exactly 402 plan_required after the grace-to-lapse boundary", async () => {
    prismaMock.familyPurchase.findMany.mockResolvedValue([]);
    const app = await fixture(new Date("2026-11-15T12:00:00.000Z"));
    const res = await app.inject({ method: "POST", url: "/protected", headers: authHeader(app) });
    expect(res.statusCode).toBe(402);
    expect(res.json()).toEqual({ error: "plan_required" });
    await app.close();
  });

  it("admits an eligible family and starts with no premium feature enabled", async () => {
    prismaMock.familyPurchase.findMany.mockResolvedValue([purchase()]);
    const app = await fixture(new Date("2026-11-15T12:00:00.000Z"));
    const res = await app.inject({ method: "POST", url: "/protected", headers: authHeader(app) });
    expect(res.statusCode).toBe(200);
    expect(PREMIUM_FEATURES).toEqual({});
    await app.close();
  });
});
