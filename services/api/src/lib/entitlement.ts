/**
 * The one seam between billing and the family plan (ADR-0041 D1/D2, issue #620).
 *
 * Billing routes describe the outcome of a store purchase as an [EntitlementChange] and hand it to
 * [grantEntitlement] / [revokeEntitlement]. Nothing on the billing side knows how a plan is stored:
 * #619 (K31) owns the `family_purchases` table and `entitlement(family)`, and replaces the store below
 * with a Prisma-backed one behind the same calls. A route must never read or write that table.
 *
 * Why a seam rather than a direct table write: the Play and Apple integrations (B2/B3) land before the
 * entitlement model (B1), and two lanes writing one table from two sides is how a schema argument turns
 * into a merge conflict. The interface is the agreement; the table is B1's to shape.
 *
 * The split between granting and revoking states is in the **types**: [grantEntitlement] cannot be
 * handed `expired` and [revokeEntitlement] cannot be handed `active`, so a caller cannot express the
 * wrong intent at all.
 */
import { createHash, createHmac } from "node:crypto";

/** `grant` is an admin-created period (ADR-0041 D1), not a store purchase. */
export type EntitlementSource = "google_play" | "app_store" | "web" | "grant";

/** A state in which the family holds the plan. */
export type GrantingState = "active" | "grace" | "on_hold";

/** A state in which it no longer does. */
export type RevokingState = "expired" | "revoked" | "refunded";

export type EntitlementState = GrantingState | RevokingState;

interface EntitlementChangeCore {
  familyId: string;
  /** The store's product (Play subscription id, Apple product id), or the grant's own label. */
  productId: string;
  /**
   * The store's expiry, ISO 8601. `null` only when there is no store expiry to report — an admin grant,
   * or a revocation the store did not date. The stand-in stores it as sent; B1 decides what a null means
   * for `entitlement(family)`.
   */
  expiresAt: string | null;
  autoRenews: boolean;
  /**
   * The store's reference: the Play purchase token, or Apple's `originalTransactionId`.
   *
   * This is the one value in here that is a credential-shaped secret. It is hashed by the store before
   * anything is persisted ([hashStoreRef]) and it is never written to a log line.
   */
  storeRef: string;
  /**
   * When the change took effect, ISO 8601: **the server's clock, unless the store's own time is
   * earlier** — a delayed push records when the store acted, a push whose store time is ahead of us
   * records our own clock rather than the future.
   */
  effectiveAt: string;
  /** Why the state moved: `verify`, or the Play notification type that carried it (`renewed`, `canceled`). */
  cause: string;
}

export type EntitlementGrant = EntitlementChangeCore & { source: EntitlementSource; state: GrantingState };

export type EntitlementRevocation = EntitlementChangeCore & { source: EntitlementSource; state: RevokingState };

/** Either half — for logging or a store that wants to see the stream. Callers pass the narrow half. */
export type EntitlementChange = EntitlementGrant | EntitlementRevocation;

export interface EntitlementStore {
  grant(change: EntitlementGrant): Promise<void>;
  revoke(change: EntitlementRevocation): Promise<void>;
  /**
   * The family a purchase already belongs to, or `null` when we have never stored it. The store hashes
   * `storeRef` with [hashStoreRef] and matches on that; the raw ref is never the index.
   */
  findFamily(source: EntitlementSource, storeRef: string): Promise<string | null>;
  /**
   * The family's opaque store account id — the value the parent app passes as Play's
   * `obfuscatedAccountId`. B1 stores a random 128-bit value per family, created on first use and
   * returned by `GET /v1/family/entitlement`, so there is no key to rotate and nothing to derive.
   */
  storeAccountId(familyId: string): Promise<string>;
}

/**
 * The value the seam persists instead of the store's reference: SHA-256 hex of the purchase token.
 *
 * A purchase token is a bearer-ish secret — anything holding it can query the purchase — so it is not
 * kept, and an unkeyed hash is enough: the input is high-entropy, so there is nothing to brute-force.
 * B1 indexes the hash; [EntitlementStore.findFamily] is the only thing that has to agree with it.
 */
export function hashStoreRef(storeRef: string): string {
  return createHash("sha256").update(storeRef, "utf8").digest("hex");
}

/**
 * The stand-in B1 replaces: purchases kept in process memory, so a restart forgets them.
 *
 * It exists so the billing routes and their tests have a working default without a table, a migration
 * or a schema decision taken in this lane. It is not persistence and must not reach production as the
 * real answer — B1's Prisma-backed store replaces it through [setEntitlementStore].
 *
 * Its account id is the one derivation here: an HMAC of the family id, because an in-memory store has
 * nowhere to keep a random value. No deploy needs a key for it — it borrows whatever secret the process
 * already holds — and B1 deletes it in favour of the stored column.
 */
class InMemoryEntitlementStore implements EntitlementStore {
  /** `source:hash` → familyId, the binding the push path resolves against. */
  private readonly bindings = new Map<string, string>();
  private readonly accountIds = new Map<string, string>();

  async grant(change: EntitlementGrant): Promise<void> {
    this.bind(change);
  }

  async revoke(change: EntitlementRevocation): Promise<void> {
    this.bind(change);
  }

  async findFamily(source: EntitlementSource, storeRef: string): Promise<string | null> {
    return this.bindings.get(`${source}:${hashStoreRef(storeRef)}`) ?? null;
  }

  async storeAccountId(familyId: string): Promise<string> {
    const existing = this.accountIds.get(familyId);
    if (existing) return existing;
    const key = process.env.JWT_SECRET ?? "dev-insecure-store-account-id";
    const created = createHmac("sha256", key).update(`osra:play:family:${familyId}`).digest("hex").slice(0, 32);
    this.accountIds.set(familyId, created);
    return created;
  }

  private bind(change: EntitlementChange): void {
    this.bindings.set(`${change.source}:${hashStoreRef(change.storeRef)}`, change.familyId);
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

/** Record that a family holds a plan. One call per verified event; the store makes it idempotent. */
export async function grantEntitlement(change: EntitlementGrant): Promise<void> {
  await store.grant(change);
}

/** Record that a family no longer holds a plan: `expired`, `revoked` or `refunded`. */
export async function revokeEntitlement(change: EntitlementRevocation): Promise<void> {
  await store.revoke(change);
}

/** The family a stored purchase belongs to — the push path's only read (see [EntitlementStore]). */
export async function findFamilyForPurchase(source: EntitlementSource, storeRef: string): Promise<string | null> {
  return store.findFamily(source, storeRef);
}

/** The family's opaque store account id — what the app sends as `obfuscatedAccountId`. */
export async function storeAccountIdFor(familyId: string): Promise<string> {
  return store.storeAccountId(familyId);
}

/**
 * Whether a state means "the family no longer holds a plan", so it goes to [revokeEntitlement].
 * `grace` and `on_hold` deliberately do **not**: ADR-0041 D3 counts both as active, so a family in
 * either keeps the plan while the store is still trying to collect.
 */
export function isRevoking(state: EntitlementState): state is RevokingState {
  return state === "revoked" || state === "expired" || state === "refunded";
}
