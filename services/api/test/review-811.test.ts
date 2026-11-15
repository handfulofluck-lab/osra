import { beforeEach, describe, expect, it, vi } from "vitest";
import { authHeader, buildApp, MockRedis, prismaMock, resetPrismaMock } from "./helpers.js";

vi.mock("../src/db.js", () => ({ prisma: prismaMock }));
vi.mock("ioredis", async () => ({ Redis: (await import("./helpers.js")).MockRedis }));

import { entitlement, grantEntitlement, revokeEntitlement, type EntitlementGrant } from "../src/lib/entitlement.js";
import { hasEnforcingPlan } from "../src/lib/planGate.js";
import { PREMIUM_FEATURES } from "../src/lib/planGate.js";
import { inviteRoutes } from "../src/routes/invites.js";
import { controlsRoutes } from "../src/routes/controls.js";
import { getRedis } from "../src/redis.js";
// @ts-expect-error the grant script is JavaScript.
import { runGrant } from "../scripts/billing/grant.mjs";

const base: EntitlementGrant = {
  familyId: "fam-1", source: "google_play", state: "active", productId: "family.monthly",
  expiresAt: "2027-01-01T00:00:00.000Z", autoRenews: true, storeRef: "synthetic-reference",
  effectiveAt: "2026-11-14T10:00:00.000Z", cause: "verify",
};
const purchase = (overrides: Record<string, unknown> = {}) => ({
  familyId: "fam-1", source: "google_play", productId: "family.monthly", storeRefHash: "a".repeat(64),
  status: "active", expiresAt: new Date(base.expiresAt!), autoRenews: true,
  lastVerifiedAt: new Date(base.effectiveAt), cause: "verify", endedAt: null,
  ...overrides,
});

beforeEach(() => {
  resetPrismaMock();
  const redis = getRedis() as unknown as MockRedis;
  const values = new Map<string, string>();
  redis.get.mockImplementation(async (key) => values.get(key) ?? null);
  redis.set.mockImplementation(async (key, value) => { values.set(key, String(value)); return "OK"; });
  redis.del.mockImplementation(async (...keys) => keys.reduce((n, key) => n + (values.delete(key) ? 1 : 0), 0));
  redis.publish.mockClear();
  values.set("invite:inv-1", JSON.stringify({ familyId: "fam-1", email: "guardian@example.com", role: "guardian", permissions: [] }));
});

describe("R3 review: immutable end of eligibility", () => {
  it("updates a newer grant rather than ignoring every existing row", async () => {
    prismaMock.familyPurchase.findUnique.mockResolvedValue(purchase());
    await grantEntitlement({ ...base, state: "grace", effectiveAt: "2026-11-15T10:00:00.000Z" });
    expect(prismaMock.familyPurchase.update).toHaveBeenCalledWith(expect.objectContaining({
      data: expect.objectContaining({ status: "grace", lastVerifiedAt: new Date("2026-11-15T10:00:00.000Z"), endedAt: null }),
    }));
  });

  it("sets ended_at on the first revocation and preserves it on later verification", async () => {
    prismaMock.familyPurchase.findUnique.mockResolvedValue(purchase());
    const effectiveAt = "2026-11-15T10:00:00.000Z";
    await revokeEntitlement({ ...base, state: "refunded", effectiveAt, expiresAt: null });
    expect(prismaMock.familyPurchase.update).toHaveBeenLastCalledWith(expect.objectContaining({
      data: expect.objectContaining({ endedAt: new Date(effectiveAt) }),
    }));

    const firstEnd = new Date("2026-10-01T00:00:00.000Z");
    prismaMock.familyPurchase.findUnique.mockResolvedValue(purchase({ status: "refunded", endedAt: firstEnd, expiresAt: null }));
    await revokeEntitlement({ ...base, state: "refunded", effectiveAt: "2026-11-15T10:00:00.000Z", expiresAt: null });
    expect(prismaMock.familyPurchase.update).toHaveBeenLastCalledWith(expect.objectContaining({
      data: expect.objectContaining({ endedAt: firstEnd, lastVerifiedAt: new Date("2026-11-15T10:00:00.000Z") }),
    }));
  });

  it("does not re-arm an old expired plan by verifying it again today", async () => {
    prismaMock.familyPurchase.findMany.mockResolvedValue([purchase({
      status: "expired", expiresAt: new Date("2026-10-01T00:00:00.000Z"),
      endedAt: new Date("2026-10-01T00:00:00.000Z"), lastVerifiedAt: new Date("2026-11-15T10:01:00.000Z"),
    })]);
    prismaMock.family.findUnique.mockResolvedValue({ id: "fam-1", timezone: "Asia/Dubai" });
    expect(await hasEnforcingPlan("fam-1", new Date("2026-11-15T10:01:00.000Z"))).toBe(false);
  });

  it("bounds grace and hold at 67 days and enforces at the next local 10:00", async () => {
    const expiresAt = new Date("2026-09-08T23:00:00.000Z");
    const held = purchase({ status: "on_hold", expiresAt, endedAt: null, lastVerifiedAt: new Date("2026-09-09T00:00:00.000Z") });
    prismaMock.familyPurchase.findMany.mockResolvedValue([held]);
    const warn = vi.fn();
    expect(await entitlement("fam-1", new Date("2026-11-14T22:00:00.000Z"), warn)).toEqual({
      plan: "family", until: expiresAt.toISOString(), source: "google_play", manage_on: "google_play",
    });
    expect(warn).not.toHaveBeenCalled();

    expect(await entitlement("fam-1", new Date("2026-11-15T00:00:00.000Z"), warn)).toEqual({
      plan: null, until: null, source: null, manage_on: null,
    });
    expect(warn).toHaveBeenCalledWith(
      { familyId: "fam-1", source: "google_play", storeRefHash: "a".repeat(64) },
      "family_plan_recovery_ceiling",
    );

    prismaMock.family.findUnique.mockResolvedValue({ id: "fam-1", timezone: "UTC" });
    expect(await hasEnforcingPlan("fam-1", new Date("2026-11-15T00:00:00.000Z"))).toBe(true);
    expect(await hasEnforcingPlan("fam-1", new Date("2026-11-15T10:00:00.000Z"))).toBe(false);
  });

  it("uses the earlier store expiry when the first recorded state is already expired", async () => {
    await revokeEntitlement({ ...base, state: "expired", expiresAt: "2026-10-01T00:00:00.000Z", effectiveAt: "2026-11-15T10:00:00.000Z" });
    expect(prismaMock.familyPurchase.create).toHaveBeenCalledWith({
      data: expect.objectContaining({
        status: "expired",
        endedAt: new Date("2026-10-01T00:00:00.000Z"),
        lastVerifiedAt: new Date("2026-11-15T10:00:00.000Z"),
      }),
    });
  });

  it.each(["P2002", "P2034"])("retries one %s conflict inside the store boundary", async (code) => {
    const transaction = prismaMock.$transaction.getMockImplementation()!;
    prismaMock.$transaction.mockRejectedValueOnce(Object.assign(new Error("synthetic conflict"), { code })).mockImplementation(transaction);
    await grantEntitlement(base);
    expect(prismaMock.$transaction).toHaveBeenCalledTimes(2);
    expect(prismaMock.familyPurchase.create).toHaveBeenCalledTimes(1);
  });
});

describe("R3 review: response projections and filtering", () => {
  it("does not expose the owner's store account id when a guardian accepts an invite", async () => {
    const row = { id: "fam-1", name: "The Family", region: "US", timezone: "UTC", timezoneSource: "default", createdAt: new Date(0), storeAccountId: "f".repeat(32) };
    prismaMock.parent.findUnique.mockResolvedValue({ id: "parent-2", familyId: "fam-2", email: "guardian@example.com", role: "guardian", permissions: [] });
    prismaMock.familyInvite.findUnique.mockResolvedValue({ id: "inv-1", familyId: "fam-1", email: "guardian@example.com", status: "pending" });
    prismaMock.parent.update.mockResolvedValue({ id: "parent-2", familyId: "fam-1", role: "guardian", permissions: [] });
    prismaMock.familyInvite.update.mockResolvedValue({ id: "inv-1", status: "accepted" });
    prismaMock.family.findUnique.mockImplementation(async ({ select }: { select?: Record<string, boolean> }) =>
      select ? Object.fromEntries(Object.keys(select).filter((key) => select[key]).map((key) => [key, row[key as keyof typeof row]])) : row,
    );
    const app = await buildApp(inviteRoutes, "/v1/family");
    const res = await app.inject({ method: "POST", url: "/v1/family/invites/inv-1/accept", headers: authHeader(app, "fam-2", "parent-2") });
    expect(res.statusCode).toBe(200);
    expect(prismaMock.family.findUnique).toHaveBeenCalledWith({
      where: { id: "fam-1" },
      select: { id: true, name: true, region: true, timezone: true, timezoneSource: true, createdAt: true },
    });
    expect(res.body).not.toContain("storeAccountId");
    expect(res.body).not.toContain("f".repeat(32));
    await app.close();
  });

  it("filters a bonus publication without hiding the parent's bonus response", async () => {
    PREMIUM_FEATURES.socialMonitoring = true;
    const app = await buildApp(controlsRoutes, "/v1/controls");
    try {
      prismaMock.child.findUnique.mockResolvedValue({ id: "child-1", familyId: "fam-1" });
      prismaMock.ruleSet.upsert.mockResolvedValue({ id: "rs-1", childId: "child-1", socialMonitoring: { enabled: true }, bonusMinutesToday: 15 });
      prismaMock.familyPurchase.findMany.mockResolvedValue([]);
      prismaMock.family.findUnique.mockResolvedValue({ id: "fam-1", timezone: "UTC" });
      const res = await app.inject({ method: "POST", url: "/v1/controls/children/child-1/bonus", headers: authHeader(app), payload: { minutes: 15 } });
      expect(res.statusCode).toBe(200);
      expect(res.json().bonusMinutesToday).toBe(15);
      const redis = getRedis() as unknown as MockRedis;
      const [channel, message] = redis.publish.mock.calls.at(-1)!;
      expect(channel).toBe("child:child-1:rules");
      expect(JSON.parse(message).socialMonitoring).toBeUndefined();
    } finally {
      delete PREMIUM_FEATURES.socialMonitoring;
      await app.close();
    }
  });
});

describe("R3 review: finite maintainer grants", () => {
  it.each(["2026-11-14T23:59:59.000Z", "2027-11-16T00:00:01.000Z"])("refuses out-of-window expiry %s before AWS", async (expiresAt) => {
    const deps = {
      awsCli: vi.fn(), executeSql: vi.fn(), log: vi.fn(),
      now: () => new Date("2026-11-15T00:00:00.000Z"),
    };
    await expect(runGrant({
      familyId: "2f4af9a1-2b59-4c61-bb0c-5e875a224ba3", expiresAt, reason: "closed-beta", secretName: "test/database",
    }, deps)).rejects.toThrow("expires_at");
    expect(deps.awsCli).not.toHaveBeenCalled();
  });
});
