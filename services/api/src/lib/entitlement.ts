/**
 * The one seam between billing and the family plan (ADR-0041 D1/D2, issue #620).
 *
 * Billing routes describe the outcome of a store purchase as an [EntitlementChange] and hand it to
 * [grantEntitlement] / [revokeEntitlement]. Nothing on the billing side knows how a plan is stored:
 * #619 (K31) owns the `family_purchases` table and `entitlement(family)`, and replaces the store below
 * with a Prisma-backed one behind the same two functions. A route must never read or write that table.
 *
 * Why a seam rather than a direct table write: the Play and Apple integrations (B2/B3) land before the
 * entitlement model (B1), and two lanes writing one table from two sides is how a schema argument turns
 * into a merge conflict. The interface is the agreement; the table is B1's to shape.
 */
export type EntitlementSource = "google" | "apple" | "web";

export type EntitlementState = "active" | "grace" | "on_hold" | "expired" | "revoked";

export interface EntitlementChange {
  familyId: string;
  source: EntitlementSource;
  state: EntitlementState;
  /** The store's own reference: the Play purchase token, or Apple's `originalTransactionId`. */
  externalId: string;
  /** When the state took effect, ISO 8601 — the store's event time, not ours. */
  effectiveAt: string;
  /** Why the state moved, in one word the route chose: `verify`, `renewed`, `canceled`, … */
  cause: string;
}

export interface EntitlementStore {
  grant(change: EntitlementChange): Promise<void>;
  revoke(change: EntitlementChange): Promise<void>;
  /**
   * The family a purchase already belongs to, or `null` when we have never stored it.
   *
   * The Play notification (RTDN) carries a purchase token and no family id, so the one thing the push
   * path needs from the seam is this lookup. It is a read and nothing else: a route never enumerates
   * families or plans, and a miss is a miss.
   */
  findFamily(source: EntitlementSource, externalId: string): Promise<string | null>;
}

/**
 * The stand-in B1 replaces: purchases kept in process memory, so a restart forgets them.
 *
 * It exists so the billing routes and their tests have a working default without a table, a migration
 * or a schema decision taken in this lane. It is not persistence and must not reach production as the
 * real answer — B1's Prisma-backed store replaces it through [setEntitlementStore].
 */
class InMemoryEntitlementStore implements EntitlementStore {
  /** One entry per applied change, oldest first — enough for a route test to read back what happened. */
  private readonly changes: EntitlementChange[] = [];
  /** `source:externalId` → familyId, the binding the push path resolves against. */
  private readonly bindings = new Map<string, string>();

  async grant(change: EntitlementChange): Promise<void> {
    this.record(change);
  }

  async revoke(change: EntitlementChange): Promise<void> {
    this.record(change);
  }

  async findFamily(source: EntitlementSource, externalId: string): Promise<string | null> {
    return this.bindings.get(`${source}:${externalId}`) ?? null;
  }

  private record(change: EntitlementChange): void {
    this.changes.push(change);
    this.bindings.set(`${change.source}:${change.externalId}`, change.familyId);
  }
}

let store: EntitlementStore = new InMemoryEntitlementStore();

/**
 * Swap the store. `null` restores a fresh in-memory one — the reset a test uses between cases, and the
 * only way to prove a route wrote through the seam rather than around it.
 */
export function setEntitlementStore(next: EntitlementStore | null): void {
  store = next ?? new InMemoryEntitlementStore();
}

/** Record that a family holds a plan. Idempotent from the caller's side: one call per verified event. */
export async function grantEntitlement(change: EntitlementChange): Promise<void> {
  await store.grant(change);
}

/** Record that a family no longer holds a plan (`revoked` or `expired`). */
export async function revokeEntitlement(change: EntitlementChange): Promise<void> {
  await store.revoke(change);
}

/** The family a stored purchase belongs to — the push path's only read (see [EntitlementStore]). */
export async function findFamilyForPurchase(source: EntitlementSource, externalId: string): Promise<string | null> {
  return store.findFamily(source, externalId);
}

/**
 * Whether a state means "the family no longer holds a plan", so it goes through [revokeEntitlement].
 * `grace` and `on_hold` deliberately do **not**: ADR-0041 D3 counts both as active, so a family in
 * either keeps the plan while the store is still trying to collect.
 */
export function isRevoking(state: EntitlementState): boolean {
  return state === "revoked" || state === "expired";
}
