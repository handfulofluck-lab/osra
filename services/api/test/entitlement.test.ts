import { beforeEach, describe, expect, it, vi } from "vitest";
import { prismaMock, resetPrismaMock } from "./helpers.js";

vi.mock("../src/db.js", () => ({ prisma: prismaMock }));

import {
  entitlement,
  grantEntitlement,
  revokeEntitlement,
  setEntitlementStore,
  storeAccountIdFor,
  type EntitlementGrant,
} from "../src/lib/entitlement.js";

const TOKEN = "synthetic-high-entropy-purchase-reference";
const base: EntitlementGrant = {
  familyId: "fam-1",
  source: "google_play",
  state: "active",
  productId: "family.monthly",
  expiresAt: "2026-12-13T00:00:00.000Z",
  autoRenews: true,
  storeRef: TOKEN,
  effectiveAt: "2026-11-13T10:00:00.000Z",
  cause: "verify",
};

function purchase(overrides: Record<string, unknown> = {}) {
  return {
    id: "purchase-1",
    familyId: "fam-1",
    source: "google_play",
    productId: "family.monthly",
    storeRefHash: "a".repeat(64),
    status: "active",
    expiresAt: new Date("2026-12-13T00:00:00.000Z"),
    autoRenews: true,
    lastVerifiedAt: new Date("2026-11-13T10:00:00.000Z"),
    cause: "verify",
    ...overrides,
  };
}

beforeEach(() => {
  resetPrismaMock();
  setEntitlementStore(null);
});

describe("durable entitlement store", () => {
  it("persists the grant with only the store-reference hash", async () => {
    await grantEntitlement(base);
    expect(prismaMock.familyPurchase.create).toHaveBeenCalledWith({
      data: expect.objectContaining({
        familyId: "fam-1",
        source: "google_play",
        status: "active",
        expiresAt: new Date(base.expiresAt!),
        lastVerifiedAt: new Date(base.effectiveAt),
        storeRefHash: expect.stringMatching(/^[0-9a-f]{64}$/),
      }),
    });
    expect(JSON.stringify(prismaMock.familyPurchase.create.mock.calls)).not.toContain(TOKEN);
  });

  it("does not rewrite an identical replay or let an older event move state backward", async () => {
    await grantEntitlement(base);
    prismaMock.familyPurchase.findUnique.mockResolvedValue(purchase());
    await grantEntitlement(base);
    await revokeEntitlement({ ...base, state: "revoked", effectiveAt: "2026-11-12T10:00:00.000Z", expiresAt: null });
    expect(prismaMock.familyPurchase.create).toHaveBeenCalledTimes(1);
    expect(prismaMock.familyPurchase.update).not.toHaveBeenCalled();
  });

  it("refuses to rebind an existing purchase to a different family", async () => {
    prismaMock.familyPurchase.findUnique.mockResolvedValue(purchase({ familyId: "fam-other" }));
    await expect(grantEntitlement(base)).rejects.toThrow("purchase_already_bound");
    expect(prismaMock.familyPurchase.create).not.toHaveBeenCalled();
    expect(prismaMock.familyPurchase.update).not.toHaveBeenCalled();
  });

  it("creates a random 128-bit store id once per family, not from the family id", async () => {
    const ids = new Map<string, string>();
    prismaMock.family.findUnique.mockImplementation(async ({ where }: { where: { id: string } }) => ({ id: where.id, storeAccountId: ids.get(where.id) ?? null }));
    prismaMock.family.updateMany.mockImplementation(async ({ where, data }: { where: { id: string }; data: { storeAccountId: string } }) => {
      ids.set(where.id, data.storeAccountId);
      return { count: 1 };
    });
    const first = await storeAccountIdFor("fam-1");
    expect(first).toMatch(/^[0-9a-f]{32}$/);
    expect(first).not.toContain("fam-1");
    expect(await storeAccountIdFor("fam-1")).toBe(first);
    expect(await storeAccountIdFor("fam-2")).not.toBe(first);
    expect(prismaMock.family.updateMany).toHaveBeenCalledTimes(2);
    // The real concurrent first-use race is covered against PostgreSQL in demo-seed-cleanup.test.ts.
  });
});

describe("entitlement selection", () => {
  const now = new Date("2026-11-15T12:00:00.000Z");

  it("returns null fields when no row is eligible", async () => {
    prismaMock.familyPurchase.findMany.mockResolvedValue([purchase({ expiresAt: new Date("2026-11-14T00:00:00.000Z") })]);
    expect(await entitlement("fam-1", now)).toEqual({ plan: null, until: null, source: null, manage_on: null });
  });

  it("chooses the latest finite expiry, then latest verification, across sources", async () => {
    prismaMock.familyPurchase.findMany.mockResolvedValue([
      purchase(),
      purchase({ id: "newer-verification", source: "app_store", lastVerifiedAt: new Date("2026-11-14T10:00:00.000Z") }),
      purchase({ id: "longer", source: "grant", expiresAt: new Date("2027-01-01T00:00:00.000Z") }),
      purchase({ id: "revoked", status: "revoked", expiresAt: new Date("2028-01-01T00:00:00.000Z") }),
    ]);
    expect(await entitlement("fam-1", now)).toEqual({ plan: "family", until: "2027-01-01T00:00:00.000Z", source: "grant", manage_on: null });
  });

  it("keeps store grace and account hold eligible beyond their reported expiry", async () => {
    prismaMock.familyPurchase.findMany.mockResolvedValue([
      purchase({ status: "grace", expiresAt: new Date("2026-11-10T00:00:00.000Z") }),
      purchase({ id: "hold", source: "app_store", status: "on_hold", expiresAt: new Date("2026-11-12T00:00:00.000Z") }),
    ]);
    expect(await entitlement("fam-1", now)).toEqual({ plan: "family", until: "2026-11-12T00:00:00.000Z", source: "app_store", manage_on: "app_store" });
  });

  it("never treats a missing expiry as lifetime, and warns without a store reference", async () => {
    const warn = vi.fn();
    prismaMock.familyPurchase.findMany.mockResolvedValue([purchase({ expiresAt: null, storeRefHash: "sensitive-hash-not-for-logs" })]);
    expect(await entitlement("fam-1", now, warn)).toEqual({ plan: null, until: null, source: null, manage_on: null });
    expect(warn).toHaveBeenCalledWith({ familyId: "fam-1" }, "family_plan_missing_expiry");
    expect(JSON.stringify(warn.mock.calls)).not.toContain("sensitive-hash-not-for-logs");
  });
});
