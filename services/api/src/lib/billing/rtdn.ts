/**
 * The core of the Play real-time developer notification (RTDN) push path (ADR-0041 D2, issue #620).
 *
 * Pub/Sub pushes `{ message: { data, messageId } }` to `POST /v1/billing/google/rtdn`, at least once.
 * This module owns the three things that are worth testing without an HTTP server: decoding the
 * envelope's payload, mapping Play's `notificationType` onto our own vocabulary, and the two pieces
 * that must be injectable — the OIDC verifier and the seen-set. The route is the thin part that turns
 * their answers into status codes.
 *
 * No key is in this file. The verifier fetches Google's published signing certificates through the
 * same [BillingTransport] the API client uses; tests inject a generated key pair and a fixture token.
 */
import { createPublicKey, verify as verifySignature, type KeyObject } from "node:crypto";
import { getRedis, setJsonNx } from "../../redis.js";
import type { BillingTransport } from "./google.js";

/** A Firebase-style developer notification. Only the fields we act on are named. */
export interface DeveloperNotification {
  packageName?: string;
  eventTimeMillis?: string;
  subscriptionNotification?: {
    version?: string;
    notificationType?: number;
    purchaseToken?: string;
    subscriptionId?: string;
  };
  testNotification?: unknown;
  /**
   * #692: a refund or a chargeback. `productType` 1 is a subscription and 2 a one-time product; the fields
   * are optional because Pub/Sub is a wire format, so the handler checks them rather than trusting the shape.
   */
  voidedPurchaseNotification?: {
    purchaseToken?: string;
    orderId?: string;
    productId?: string;
    productType?: number;
  };
}

export class MalformedNotification extends Error {
  readonly code = "malformed_notification";
  constructor(readonly reason: string) {
    super(`malformed notification: ${reason}`);
    this.name = "MalformedNotification";
  }
}

/** Decode `message.data`: base64 of a JSON [DeveloperNotification]. */
export function decodeNotification(data: string): DeveloperNotification {
  let json: string;
  try {
    json = Buffer.from(data, "base64").toString("utf8");
  } catch {
    throw new MalformedNotification("data_not_base64");
  }
  let parsed: unknown;
  try {
    parsed = JSON.parse(json);
  } catch {
    throw new MalformedNotification("data_not_json");
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new MalformedNotification("data_not_object");
  }
  const notification = parsed as DeveloperNotification;
  const sub = notification.subscriptionNotification;
  if (sub !== undefined) {
    if (!sub || typeof sub !== "object") throw new MalformedNotification("subscription_notification_not_object");
    if (typeof sub.purchaseToken !== "string" || sub.purchaseToken.length === 0) {
      throw new MalformedNotification("missing_purchase_token");
    }
  }
  return notification;
}

/**
 * Play's `SubscriptionNotification.NotificationType`, in the numbering the Developer API uses.
 *
 * The type is **a label, not a decision**: every push re-fetches `subscriptionsv2` and takes the state
 * from there, which is Google's own advice. A type carries no state mapping here on purpose — mapping
 * type 3 (`canceled`) to "revoked" would cut off a family that has paid to the end of the period, and
 * an unknown number must not stop an authoritative update from landing.
 */
const NOTIFICATION_CAUSES: Readonly<Record<number, string>> = {
  1: "recovered",
  2: "renewed",
  3: "canceled",
  4: "purchased",
  5: "on_hold",
  6: "in_grace_period",
  7: "restarted",
  8: "price_change",
  10: "paused",
  12: "revoked",
  13: "expired",
};

/**
 * The `cause` a notification records, and whether we recognised the number. A caller logs the unknown
 * ones (never a silent drop) and still applies Play's state.
 */
export function notificationCause(type: number | undefined): { cause: string; known: boolean } {
  if (typeof type !== "number" || !Number.isInteger(type)) {
    return { cause: "unknown_notification_type", known: false };
  }
  const name = NOTIFICATION_CAUSES[type];
  return name ? { cause: name, known: true } : { cause: `unknown_notification_type:${type}`, known: false };
}

/** The `messageId`s already handled. A push is at least once, so this is what stops a double write. */
export interface SeenMessages {
  /** Claim an id: `true` the first time, `false` for a redelivery. */
  claim(messageId: string): Promise<boolean>;
  /** Hand a claim back when processing failed, so the store's own retry can still apply it. */
  release(messageId: string): Promise<void>;
}

/**
 * The production seen-set: Redis `SET NX EX`, the same helper the pairing and reset flows use.
 *
 * Seven days is well past Pub/Sub's default retention, so a redelivery cannot outlive its key.
 */
export function createRedisSeenMessages(ttlSeconds = 7 * 24 * 3600): SeenMessages {
  const key = (messageId: string) => `billing:rtdn:seen:${messageId}`;
  return {
    async claim(messageId: string): Promise<boolean> {
      return setJsonNx(key(messageId), { at: new Date().toISOString() }, ttlSeconds);
    },
    async release(messageId: string): Promise<void> {
      await getRedis().del(key(messageId));
    },
  };
}

/**
 * In-memory seen-set for tests and for a single-process dev stack. It forgets on restart, which is
 * exactly why it is not the production default: a redeploy between two deliveries of the same message
 * would process both.
 */
export function createMemorySeenMessages(options: { ttlMs?: number; now?: () => number } = {}): SeenMessages {
  const ttlMs = options.ttlMs ?? 7 * 24 * 3600 * 1000;
  const now = options.now ?? (() => Date.now());
  const seen = new Map<string, number>();
  const prune = () => {
    const cutoff = now() - ttlMs;
    for (const [id, at] of seen) if (at < cutoff) seen.delete(id);
  };
  return {
    async claim(messageId: string): Promise<boolean> {
      prune();
      if (seen.has(messageId)) return false;
      seen.set(messageId, now());
      return true;
    },
    async release(messageId: string): Promise<void> {
      seen.delete(messageId);
    },
  };
}

/** Who signed the push. Only `email` is authoritative for us; the rest is for the log. */
export interface PushIdentity {
  email: string;
  subject: string;
  issuer: string;
}

export class OidcRejected extends Error {
  readonly code = "invalid_push_token";
  constructor(readonly reason: string) {
    super(`invalid push token: ${reason}`);
    this.name = "OidcRejected";
  }
}

/** `(token) => identity`. Injectable so a route test passes a fake and no certificate is fetched. */
export type OidcVerifier = (token: string) => Promise<PushIdentity>;

export interface GoogleOidcOptions {
  /** The audience the Pub/Sub subscription was created with; a token for anything else is refused. */
  audience: string;
  /** The push subscription's service-account address; any other signer is refused. */
  serviceAccountEmail: string;
  issuer?: string;
  certsUrl?: string;
  transport?: BillingTransport;
  now?: () => number;
  clockSkewSeconds?: number;
}

/** Google signs OIDC tokens with `accounts.google.com`, and has published both spellings. */
const GOOGLE_ISSUERS = new Set(["https://accounts.google.com", "accounts.google.com"]);
const DEFAULT_CERTS_URL = "https://www.googleapis.com/oauth2/v3/certs";

interface Jwk {
  kid?: string;
  kty?: string;
  n?: string;
  e?: string;
}

function decodeJsonPart(part: string, what: string): Record<string, unknown> {
  try {
    const value = JSON.parse(Buffer.from(part, "base64url").toString("utf8"));
    if (!value || typeof value !== "object") throw new Error("not an object");
    return value as Record<string, unknown>;
  } catch {
    throw new OidcRejected(`${what}_unreadable`);
  }
}

/**
 * Verify a Pub/Sub push token: signature against Google's published certificates, then issuer,
 * audience, signer address and lifetime. Everything is checked here rather than in the route, so the
 * route's 401 means "this verifier said no" and nothing weaker.
 */
export function createGoogleOidcVerifier(options: GoogleOidcOptions): OidcVerifier {
  const transport = options.transport ?? ((url, init) => fetch(url, init));
  const now = options.now ?? (() => Date.now());
  const skew = options.clockSkewSeconds ?? 60;
  const certsUrl = options.certsUrl ?? DEFAULT_CERTS_URL;
  const expectedIssuers = new Set([...(options.issuer ? [options.issuer] : []), ...GOOGLE_ISSUERS]);
  let certs: { keys: Map<string, KeyObject>; fetchedAtMs: number } | null = null;

  async function fetchCerts(): Promise<Map<string, KeyObject>> {
    let res: Response;
    try {
      res = await transport(certsUrl, { method: "GET" });
    } catch (err) {
      throw new OidcRejected(`certs_transport:${(err as Error).message}`);
    }
    if (!res.ok) throw new OidcRejected(`certs_status_${res.status}`);
    const body = (await res.json().catch(() => null)) as { keys?: Jwk[] } | null;
    if (!body || !Array.isArray(body.keys)) throw new OidcRejected("certs_unreadable");
    const keys = new Map<string, KeyObject>();
    for (const jwk of body.keys) {
      if (!jwk?.kid || jwk.kty !== "RSA" || !jwk.n || !jwk.e) continue;
      try {
        keys.set(jwk.kid, createPublicKey({ key: { kty: "RSA", n: jwk.n, e: jwk.e }, format: "jwk" }));
      } catch {
        // A malformed certificate is skipped, not fatal: another key may verify the token.
      }
    }
    certs = { keys, fetchedAtMs: now() };
    return keys;
  }

  async function keyFor(kid: string): Promise<KeyObject> {
    // Reuse a warm cache; refetch when the kid is unknown (Google rotates certificates) or it is stale.
    if (certs && certs.keys.has(kid) && now() - certs.fetchedAtMs < 3600_000) return certs.keys.get(kid)!;
    const keys = await fetchCerts();
    const key = keys.get(kid);
    if (!key) throw new OidcRejected("unknown_signing_key");
    return key;
  }

  return async (token: string): Promise<PushIdentity> => {
    const parts = token.split(".");
    if (parts.length !== 3) throw new OidcRejected("not_a_jwt");
    const [encodedHeader, encodedPayload, encodedSignature] = parts;

    const header = decodeJsonPart(encodedHeader, "header");
    if (header.alg !== "RS256") throw new OidcRejected(`unsupported_alg:${String(header.alg)}`);
    const kid = typeof header.kid === "string" ? header.kid : null;
    if (!kid) throw new OidcRejected("missing_kid");

    const payload = decodeJsonPart(encodedPayload, "payload");
    const key = await keyFor(kid);
    const signed = Buffer.from(`${encodedHeader}.${encodedPayload}`, "utf8");
    let valid = false;
    try {
      valid = verifySignature("RSA-SHA256", signed, key, Buffer.from(encodedSignature, "base64url"));
    } catch {
      valid = false;
    }
    if (!valid) throw new OidcRejected("bad_signature");

    const issuer = typeof payload.iss === "string" ? payload.iss : "";
    if (!expectedIssuers.has(issuer)) throw new OidcRejected(`unexpected_issuer:${issuer || "missing"}`);

    const audiences = Array.isArray(payload.aud) ? payload.aud : [payload.aud];
    if (!audiences.includes(options.audience)) throw new OidcRejected("unexpected_audience");

    const email = typeof payload.email === "string" ? payload.email : "";
    if (email.toLowerCase() !== options.serviceAccountEmail.toLowerCase()) throw new OidcRejected("unexpected_signer");
    if (payload.email_verified === false) throw new OidcRejected("signer_email_unverified");

    const nowSeconds = Math.floor(now() / 1000);
    if (typeof payload.exp !== "number" || nowSeconds > payload.exp + skew) throw new OidcRejected("expired");
    if (typeof payload.iat === "number" && nowSeconds < payload.iat - skew) throw new OidcRejected("issued_in_future");

    return {
      email,
      subject: typeof payload.sub === "string" ? payload.sub : "",
      issuer,
    };
  };
}
