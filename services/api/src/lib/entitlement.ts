/**
 * ADR-0041 D1/D2: the billing routes describe a verified store outcome; this module owns its durable
 * family-plan representation. A raw purchase reference is hashed before persistence and never logged.
 */
import { createHash, randomBytes } from "node:crypto";
import { prisma } from "../db.js";

/** `grant` is an admin-created finite period, not a store purchase. */
export type EntitlementSource = "google_play" | "app_store" | "web" | "grant";
export type GrantingState = "active" | "grace" | "on_hold";
export type RevokingState = "expired" | "revoked" | "refunded";
export type EntitlementState = GrantingState | RevokingState;

interface EntitlementChangeCore {
  familyId: string;
  productId: string;
  /** The store's finite expiry. Null is retained defensively but is never a lifetime plan. */
  expiresAt: string | null;
  autoRenews: boolean;
  /** The raw store reference exists only at this boundary; its SHA-256 is what is persisted. */
  storeRef: string;
  /** The earlier of the server's clock and the store's effective time, supplied by the caller. */
  effectiveAt: string;
  cause: string;
}

export type EntitlementGrant = EntitlementChangeCore & { source: EntitlementSource; state: GrantingState };
export type EntitlementRevocation = EntitlementChangeCore & { source: EntitlementSource; state: RevokingState };
export type EntitlementChange = EntitlementGrant | EntitlementRevocation;

export interface EntitlementStore {
  grant(change: EntitlementGrant): Promise<void>;
  revoke(change: EntitlementRevocation): Promise<void>;
  findFamily(source: EntitlementSource, storeRef: string): Promise<string | null>;
  storeAccountId(familyId: string): Promise<string>;
}

export interface EntitlementResponse {
  plan: "family" | null;
  until: string | null;
  source: EntitlementSource | null;
  manage_on: Exclude<EntitlementSource, "grant"> | null;
}

export type EntitlementWarning = (fields: { familyId: string }, message: string) => void;

export function hashStoreRef(storeRef: string): string {
  return createHash("sha256").update(storeRef, "utf8").digest("hex");
}

class PrismaEntitlementStore implements EntitlementStore {
  grant(change: EntitlementGrant): Promise<void> {
    return this.apply(change);
  }

  revoke(change: EntitlementRevocation): Promise<void> {
    return this.apply(change);
  }

  private async apply(change: EntitlementChange): Promise<void> {
    const effectiveAt = new Date(change.effectiveAt);
    const storeRefHash = hashStoreRef(change.storeRef);
    for (let attempt = 0; ; attempt++) {
      try {
        await prisma.$transaction(async (tx) => {
          const where = { source_storeRefHash: { source: change.source, storeRefHash } };
          const existing = await tx.familyPurchase.findUnique({ where });
          if (existing && existing.familyId !== change.familyId) throw new Error("purchase_already_bound");
          if (existing && existing.lastVerifiedAt >= effectiveAt) return;
          // An undated revocation must not erase the expiry the store previously reported.
          const expiresAt = change.expiresAt === null ? existing?.expiresAt ?? null : new Date(change.expiresAt);
          const firstEnd = !isRevoking(change.state)
            ? null
            : change.state === "expired"
              ? new Date(Math.min(expiresAt?.getTime() ?? effectiveAt.getTime(), effectiveAt.getTime()))
              : existing && isRevoking(existing.status as EntitlementState) ? existing.endedAt ?? existing.lastVerifiedAt : effectiveAt;
          const data = {
            familyId: change.familyId,
            source: change.source,
            productId: change.productId,
            storeRefHash,
            status: change.state,
            expiresAt,
            autoRenews: change.autoRenews,
            lastVerifiedAt: effectiveAt,
            endedAt: firstEnd,
            cause: change.cause,
          };
          if (existing) await tx.familyPurchase.update({ where, data });
          else await tx.familyPurchase.create({ data });
        }, { isolationLevel: "Serializable" });
        return;
      } catch (error) {
        const code = (error as { code?: unknown }).code;
        if (attempt > 0 || (code !== "P2002" && code !== "P2034")) throw error;
      }
    }
  }

  async findFamily(source: EntitlementSource, storeRef: string): Promise<string | null> {
    const row = await prisma.familyPurchase.findUnique({
      where: { source_storeRefHash: { source, storeRefHash: hashStoreRef(storeRef) } },
      select: { familyId: true },
    });
    return row?.familyId ?? null;
  }

  async storeAccountId(familyId: string): Promise<string> {
    const existing = await prisma.family.findUnique({ where: { id: familyId }, select: { storeAccountId: true } });
    if (existing?.storeAccountId) return existing.storeAccountId;
    const created = randomBytes(16).toString("hex");
    // Another concurrent request may win. Re-read the winner rather than returning an id we did not store.
    await prisma.family.updateMany({ where: { id: familyId, storeAccountId: null }, data: { storeAccountId: created } });
    const stored = await prisma.family.findUnique({ where: { id: familyId }, select: { storeAccountId: true } });
    if (!stored?.storeAccountId) throw new Error("family_not_found");
    return stored.storeAccountId;
  }
}

let store: EntitlementStore = new PrismaEntitlementStore();

/** A test can inject the B2 fake. Null restores the production Prisma store, not shared process memory. */
export function setEntitlementStore(next: EntitlementStore | null): void {
  store = next ?? new PrismaEntitlementStore();
}

export async function grantEntitlement(change: EntitlementGrant): Promise<void> {
  await store.grant(change);
}

export async function revokeEntitlement(change: EntitlementRevocation): Promise<void> {
  await store.revoke(change);
}

export async function findFamilyForPurchase(source: EntitlementSource, storeRef: string): Promise<string | null> {
  return store.findFamily(source, storeRef);
}

export async function storeAccountIdFor(familyId: string): Promise<string> {
  return store.storeAccountId(familyId);
}

/** Only the server computes this. Grace and account hold follow the store, even beyond expires_at. */
export async function entitlement(
  familyId: string,
  now = new Date(),
  warn: EntitlementWarning = console.warn,
): Promise<EntitlementResponse> {
  const rows = await prisma.familyPurchase.findMany({ where: { familyId } });
  const eligible = rows.filter((row) => {
    if (isRevoking(row.status as EntitlementState)) return false;
    if (!row.expiresAt) {
      warn({ familyId }, "family_plan_missing_expiry");
      return false;
    }
    return row.status === "grace" || row.status === "on_hold" || (row.status === "active" && now < row.expiresAt);
  });
  eligible.sort((a, b) =>
    b.expiresAt!.getTime() - a.expiresAt!.getTime() || b.lastVerifiedAt.getTime() - a.lastVerifiedAt.getTime(),
  );
  const best = eligible[0];
  if (!best) return { plan: null, until: null, source: null, manage_on: null };
  const source = best.source as EntitlementSource;
  return {
    plan: "family",
    until: best.expiresAt!.toISOString(),
    source,
    manage_on: source === "grant" ? null : source,
  };
}

export function isRevoking(state: EntitlementState): state is RevokingState {
  return state === "revoked" || state === "expired" || state === "refunded";
}
