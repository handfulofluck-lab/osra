/**
 * Google Play Developer API client for the family plan (ADR-0041 D2, issue #620).
 *
 * Two calls, both through an injectable [BillingTransport] so a test passes fixtures and no socket is
 * opened: `purchases.subscriptionsv2.get` (what the purchase is) and
 * `purchases.subscriptions.acknowledge` (tell Play we delivered it).
 *
 * No credential lives here. [createServiceAccountTokenProvider] takes the service-account JSON as a
 * string the caller obtained from a secrets store by name; this module never reads a file, an env var
 * holding a key, or a repository path. The access token it mints is held in memory only.
 */
import { createHmac, createSign, timingSafeEqual } from "node:crypto";
import type { EntitlementState } from "../entitlement.js";

/** `(url, init) => Response`. The default is global `fetch`; tests inject a fixture table. */
export type BillingTransport = (url: string, init: RequestInit) => Promise<Response>;

/** What a verified Play purchase means to us, already normalised to our own vocabulary. */
export interface VerifiedPurchase {
  /**
   * The opaque per-family id Play echoes back from `externalAccountIdentifiers`. ADR-0041 D2 names this
   * field for the derivation, but the value is one-way (see [obfuscatedAccountIdFor]): it is the id to
   * *compare*, not a family id to look up.
   */
  familyIdFromObfuscatedAccountId: string | null;
  state: EntitlementState;
  /** The store reference: the Play purchase token, which is what a later RTDN carries. */
  externalId: string;
  /** Latest `lineItems[].expiryTime`, ISO 8601, or `null` when Play sent none. */
  expiryTime: string | null;
  productId: string;
  acknowledgementState: "pending" | "acknowledged" | "unknown";
}

/**
 * Reasons a `/verify` call is refused. Each carries a stable `code`, which is what the route sends and
 * the client reads; the message is for our logs and never reaches the caller.
 */
export class PurchaseRejected extends Error {
  readonly code = "purchase_rejected";
  constructor(readonly reason: string) {
    super(`purchase rejected: ${reason}`);
    this.name = "PurchaseRejected";
  }
}

/** The purchase is real but bound to another family's `obfuscatedAccountId`. */
export class PurchaseAlreadyOwned extends Error {
  readonly code = "purchase_owned_by_another_family";
  constructor(readonly reason: string) {
    super(`purchase belongs to another family: ${reason}`);
    this.name = "PurchaseAlreadyOwned";
  }
}

/** Play did not answer, or answered with a fault of its own: the client should retry later. */
export class PlayUnavailable extends Error {
  readonly code = "play_unavailable";
  constructor(readonly reason: string) {
    super(`play unavailable: ${reason}`);
    this.name = "PlayUnavailable";
  }
}

export interface PlayClient {
  verifySubscription(purchaseToken: string): Promise<VerifiedPurchase>;
  acknowledgeSubscription(purchaseToken: string, productId: string): Promise<void>;
}

export interface PlayClientOptions {
  /** The applicationId from the Android manifest, e.g. `com.osratech.child.full`. */
  packageName: string;
  /** Fresh OAuth bearer token for the Developer API. Re-read per call; the provider caches itself. */
  getAccessToken: () => Promise<string>;
  transport?: BillingTransport;
  /** Default `https://androidpublisher.googleapis.com`. */
  baseUrl?: string;
}

const DEFAULT_BASE_URL = "https://androidpublisher.googleapis.com";

const defaultTransport: BillingTransport = (url, init) => fetch(url, init);

/**
 * The `obfuscatedAccountId` an Android purchase carries for this family.
 *
 * ADR-0041 D2 requires an id that is **opaque** — never an email, a name or the raw family id — and
 * stable, because the value the app sends at purchase time must equal the value the server derives
 * when it verifies. So it is a keyed hash: same family and key, same id; without the key the id says
 * nothing about the family. 32 hex characters (128 bits) fits Play's 64-character limit.
 *
 * The key must survive a deploy or every stored purchase stops matching, which is why it is its own
 * setting rather than a literal. `JWT_SECRET` is the fallback so a dev stack works with no new setup;
 * a production deploy sets `BILLING_ACCOUNT_ID_KEY`.
 */
export function obfuscatedAccountIdFor(familyId: string): string {
  const key = process.env.BILLING_ACCOUNT_ID_KEY ?? process.env.JWT_SECRET ?? "dev-insecure-billing-account-id";
  return createHmac("sha256", key).update(`osra:play:family:${familyId}`).digest("hex").slice(0, 32);
}

/** Constant-time comparison of two derived ids (they are not bearer secrets, but nothing here needs to leak a prefix). */
export function accountIdMatches(expected: string, actual: string | null): boolean {
  if (!actual) return false;
  const a = Buffer.from(expected, "utf8");
  const b = Buffer.from(actual, "utf8");
  return a.length === b.length && timingSafeEqual(a, b);
}

/** Play's `SubscriptionState` → our five states. An unknown string is a rejected purchase, never a guess. */const SUBSCRIPTION_STATES: Readonly<Record<string, EntitlementState>> = {
  SUBSCRIPTION_STATE_ACTIVE: "active",
  SUBSCRIPTION_STATE_IN_GRACE_PERIOD: "grace",
  // Account hold and pause both stop access while the family still owns the subscription; D3 treats
  // hold and grace as active for product purposes, and `on_hold` is the seam's word for "still ours".
  SUBSCRIPTION_STATE_ON_HOLD: "on_hold",
  SUBSCRIPTION_STATE_PAUSED: "on_hold",
  SUBSCRIPTION_STATE_PENDING: "on_hold",
  SUBSCRIPTION_STATE_CANCELED: "revoked",
  SUBSCRIPTION_STATE_EXPIRED: "expired",
};

interface SubscriptionPurchaseV2 {
  subscriptionState?: string;
  acknowledgementState?: string;
  externalAccountIdentifiers?: { obfuscatedExternalAccountId?: string | null } | null;
  lineItems?: Array<{ productId?: string; expiryTime?: string }> | null;
}

function acknowledgementState(raw: string | undefined): VerifiedPurchase["acknowledgementState"] {
  if (raw === "ACKNOWLEDGEMENT_STATE_PENDING") return "pending";
  if (raw === "ACKNOWLEDGEMENT_STATE_ACKNOWLEDGED") return "acknowledged";
  return "unknown";
}

/** Turn a `subscriptionsv2.get` body into [VerifiedPurchase]; a shape we do not recognise is refused. */
export function normaliseSubscriptionPurchase(raw: unknown, purchaseToken: string): VerifiedPurchase {
  if (!raw || typeof raw !== "object") throw new PurchaseRejected("unreadable_purchase");
  const body = raw as SubscriptionPurchaseV2;

  const state = body.subscriptionState ? SUBSCRIPTION_STATES[body.subscriptionState] : undefined;
  if (!state) throw new PurchaseRejected(`unknown_subscription_state:${body.subscriptionState ?? "missing"}`);

  const lineItems = Array.isArray(body.lineItems) ? body.lineItems : [];
  const productId = lineItems.find((item) => typeof item?.productId === "string" && item.productId)?.productId;
  if (!productId) throw new PurchaseRejected("missing_product_id");

  // A purchase with several line items is entitled until the last of them lapses.
  const expiryTime = lineItems.reduce<string | null>((latest, item) => {
    const value = typeof item?.expiryTime === "string" ? item.expiryTime : null;
    if (!value) return latest;
    return latest === null || Date.parse(value) > Date.parse(latest) ? value : latest;
  }, null);

  const obfuscated = body.externalAccountIdentifiers?.obfuscatedExternalAccountId;

  return {
    familyIdFromObfuscatedAccountId: typeof obfuscated === "string" && obfuscated ? obfuscated : null,
    state,
    externalId: purchaseToken,
    expiryTime,
    productId,
    acknowledgementState: acknowledgementState(body.acknowledgementState),
  };
}

/**
 * A status Play answered that is not a purchase we can use. `400`/`404`/`410` mean the token is unknown
 * or spent (forged, replayed, or from another package); `401`/`403` mean *our* credential is wrong,
 * which is not the caller's fault and must not be reported as a forged purchase; `429`/`5xx` are Play's.
 */
function failureFor(status: number, what: string): PurchaseRejected | PlayUnavailable {
  if (status === 400 || status === 404 || status === 410) return new PurchaseRejected(`${what}_status_${status}`);
  if (status === 401 || status === 403) return new PlayUnavailable(`${what}_credentials_refused_${status}`);
  return new PlayUnavailable(`${what}_status_${status}`);
}

/**
 * Refuse a purchase that is not bound to this family.
 *
 * A purchase with no `obfuscatedAccountId` is not ours either: we cannot prove it was bought for this
 * family, and a family that never sent one bought through a path this server does not recognise.
 */
export function assertPurchaseBelongsToFamily(expectedAccountId: string, purchase: VerifiedPurchase): void {
  if (!accountIdMatches(expectedAccountId, purchase.familyIdFromObfuscatedAccountId)) {
    throw new PurchaseAlreadyOwned(purchase.familyIdFromObfuscatedAccountId ? "obfuscated_account_id_mismatch" : "missing_obfuscated_account_id");
  }
}

export function createPlayClient(options: PlayClientOptions): PlayClient {
  const transport = options.transport ?? defaultTransport;
  const base = options.baseUrl ?? DEFAULT_BASE_URL;
  const appPath = `${base}/androidpublisher/v3/applications/${encodeURIComponent(options.packageName)}`;

  async function call(url: string, init: RequestInit): Promise<Response> {
    const accessToken = await options.getAccessToken();
    try {
      return await transport(url, {
        ...init,
        headers: { authorization: `Bearer ${accessToken}`, ...(init.headers as Record<string, string> | undefined) },
      });
    } catch (err) {
      throw new PlayUnavailable(`transport:${(err as Error).message}`);
    }
  }

  return {
    async verifySubscription(purchaseToken: string): Promise<VerifiedPurchase> {
      const url = `${appPath}/purchases/subscriptionsv2/tokens/${encodeURIComponent(purchaseToken)}`;
      const res = await call(url, { method: "GET" });
      if (!res.ok) throw failureFor(res.status, "verify");
      let body: unknown;
      try {
        body = await res.json();
      } catch {
        throw new PlayUnavailable("verify_unreadable_body");
      }
      return normaliseSubscriptionPurchase(body, purchaseToken);
    },

    async acknowledgeSubscription(purchaseToken: string, productId: string): Promise<void> {
      const url = `${appPath}/purchases/subscriptions/${encodeURIComponent(productId)}/tokens/${encodeURIComponent(purchaseToken)}:acknowledge`;
      const res = await call(url, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: "{}",
      });
      if (res.ok) return;
      // Acknowledging twice is not a failure: the purchase is acknowledged, which is all we wanted.
      if (res.status === 400 || res.status === 409) {
        const text = await res.text().catch(() => "");
        if (/already/i.test(text)) return;
        throw new PurchaseRejected(`acknowledge_status_${res.status}`);
      }
      throw failureFor(res.status, "acknowledge");
    },
  };
}

interface ServiceAccountKey {
  client_email?: string;
  private_key?: string;
  token_uri?: string;
}

const ANDROID_PUBLISHER_SCOPE = "https://www.googleapis.com/auth/androidpublisher";
const DEFAULT_TOKEN_URI = "https://oauth2.googleapis.com/token";

/**
 * Mint Developer API access tokens from a service-account key, in memory, with the standard OAuth
 * JWT-bearer exchange. The key is the string the caller fetched from a secrets store by name; nothing
 * about it is written anywhere, and the token lives until the next request needs a fresh one.
 *
 * `transport` is shared with the API calls, so a test sees the whole exchange as fixture data.
 */
export function createServiceAccountTokenProvider(
  serviceAccountJson: string,
  options: { transport?: BillingTransport; now?: () => number } = {},
): () => Promise<string> {
  const transport = options.transport ?? defaultTransport;
  const now = options.now ?? (() => Date.now());
  let cached: { token: string; expiresAtMs: number } | null = null;
  let inflight: Promise<string> | null = null;

  async function exchange(): Promise<string> {
    let key: ServiceAccountKey;
    try {
      key = JSON.parse(serviceAccountJson) as ServiceAccountKey;
    } catch {
      throw new PlayUnavailable("service_account_unreadable");
    }
    if (!key.client_email || !key.private_key) throw new PlayUnavailable("service_account_incomplete");

    const issuedAt = Math.floor(now() / 1000);
    const claims = {
      iss: key.client_email,
      scope: ANDROID_PUBLISHER_SCOPE,
      aud: key.token_uri ?? DEFAULT_TOKEN_URI,
      iat: issuedAt,
      exp: issuedAt + 3600,
    };
    const encode = (value: unknown) => Buffer.from(JSON.stringify(value), "utf8").toString("base64url");
    const unsigned = `${encode({ alg: "RS256", typ: "JWT" })}.${encode(claims)}`;
    const signer = createSign("RSA-SHA256");
    signer.update(unsigned);
    signer.end();
    // A key stored in a JSON secret carries its newlines escaped once.
    const assertion = `${unsigned}.${signer.sign(key.private_key.replace(/\\n/g, "\n")).toString("base64url")}`;

    let res: Response;
    try {
      res = await transport(key.token_uri ?? DEFAULT_TOKEN_URI, {
        method: "POST",
        headers: { "content-type": "application/x-www-form-urlencoded" },
        body: new URLSearchParams({
          grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
          assertion,
        }).toString(),
      });
    } catch (err) {
      throw new PlayUnavailable(`token_transport:${(err as Error).message}`);
    }
    if (!res.ok) throw new PlayUnavailable(`token_status_${res.status}`);

    const body = (await res.json().catch(() => null)) as { access_token?: string; expires_in?: number } | null;
    if (!body?.access_token) throw new PlayUnavailable("token_missing_access_token");
    cached = { token: body.access_token, expiresAtMs: now() + (body.expires_in ?? 3600) * 1000 };
    return cached.token;
  }

  return async (): Promise<string> => {
    // A minute of slack so a token is never sent at the edge of its life.
    if (cached && cached.expiresAtMs - 60_000 > now()) return cached.token;
    inflight ??= exchange().finally(() => {
      inflight = null;
    });
    return inflight;
  };
}
