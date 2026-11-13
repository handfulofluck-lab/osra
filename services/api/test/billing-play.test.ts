import { describe, expect, it, vi } from "vitest";
import { createSign, generateKeyPairSync } from "node:crypto";

import {
  PlayUnavailable,
  PurchaseAlreadyOwned,
  PurchaseRejected,
  assertPurchaseBelongsToFamily,
  createPlayClient,
  createServiceAccountTokenProvider,
  normaliseSubscriptionPurchase,
} from "../src/lib/billing/google.js";
import {
  MalformedNotification,
  OidcRejected,
  createGoogleOidcVerifier,
  decodeNotification,
} from "../src/lib/billing/rtdn.js";

const PRODUCT = "com.osratech.family.monthly";
const PACKAGE = "com.osratech.parent";
const BASE = "https://androidpublisher.googleapis.com";

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
}

function subscriptionBody(overrides: Record<string, unknown> = {}) {
  return {
    kind: "androidpublisher#subscriptionPurchaseV2",
    subscriptionState: "SUBSCRIPTION_STATE_ACTIVE",
    acknowledgementState: "ACKNOWLEDGEMENT_STATE_PENDING",
    externalAccountIdentifiers: { obfuscatedExternalAccountId: "abc123" },
    lineItems: [{ productId: PRODUCT, expiryTime: "2026-12-13T00:00:00.000Z", autoRenewingPlan: { autoRenewEnabled: true } }],
    ...overrides,
  };
}

describe("the Play Developer API client", () => {
  it("verifies a purchase through the injected transport and normalises it", async () => {
    const calls: Array<{ url: string; init: RequestInit }> = [];
    const client = createPlayClient({
      packageName: PACKAGE,
      getAccessToken: async () => "access-token",
      transport: async (url, init) => {
        calls.push({ url, init });
        return jsonResponse(subscriptionBody());
      },
    });

    const purchase = await client.verifySubscription("tok+1");

    expect(calls).toHaveLength(1);
    expect(calls[0].url).toBe(`${BASE}/androidpublisher/v3/applications/${PACKAGE}/purchases/subscriptionsv2/tokens/tok%2B1`);
    expect(calls[0].init.method).toBe("GET");
    expect((calls[0].init.headers as Record<string, string>).authorization).toBe("Bearer access-token");
    expect(purchase).toEqual({
      familyIdFromObfuscatedAccountId: "abc123",
      state: "active",
      storeRef: "tok+1",
      expiryTime: "2026-12-13T00:00:00.000Z",
      productId: PRODUCT,
      autoRenews: true,
      acknowledgementState: "pending",
    });
  });

  it("acknowledges through the product's own endpoint", async () => {
    const calls: Array<{ url: string; init: RequestInit }> = [];
    const client = createPlayClient({
      packageName: PACKAGE,
      getAccessToken: async () => "access-token",
      transport: async (url, init) => {
        calls.push({ url, init });
        return jsonResponse({});
      },
    });

    await client.acknowledgeSubscription("tok-1", PRODUCT);

    expect(calls[0].url).toBe(`${BASE}/androidpublisher/v3/applications/${PACKAGE}/purchases/subscriptions/${PRODUCT}/tokens/tok-1:acknowledge`);
    expect(calls[0].init.method).toBe("POST");
  });

  it("treats a second acknowledgement as success", async () => {
    const client = createPlayClient({
      packageName: PACKAGE,
      getAccessToken: async () => "access-token",
      transport: async () => new Response("The purchase has already been acknowledged.", { status: 400 }),
    });
    await expect(client.acknowledgeSubscription("tok-1", PRODUCT)).resolves.toBeUndefined();
  });

  it("maps Play's statuses onto the three typed refusals", async () => {
    const at = (status: number) =>
      createPlayClient({ packageName: PACKAGE, getAccessToken: async () => "t", transport: async () => jsonResponse({}, status) });

    await expect(at(404).verifySubscription("t")).rejects.toBeInstanceOf(PurchaseRejected);
    await expect(at(410).verifySubscription("t")).rejects.toBeInstanceOf(PurchaseRejected);
    await expect(at(500).verifySubscription("t")).rejects.toBeInstanceOf(PlayUnavailable);
    // Our own credential being refused is not the caller's forged purchase.
    await expect(at(403).verifySubscription("t")).rejects.toBeInstanceOf(PlayUnavailable);

    const offline = createPlayClient({
      packageName: PACKAGE,
      getAccessToken: async () => "t",
      transport: async () => {
        throw new Error("ECONNRESET");
      },
    });
    await expect(offline.verifySubscription("t")).rejects.toBeInstanceOf(PlayUnavailable);
  });
});

describe("normalising a subscriptionsv2 purchase", () => {
  it("maps every state Play can send", () => {
    const cases: Array<[string, string]> = [
      ["SUBSCRIPTION_STATE_ACTIVE", "active"],
      ["SUBSCRIPTION_STATE_IN_GRACE_PERIOD", "grace"],
      ["SUBSCRIPTION_STATE_ON_HOLD", "on_hold"],
      ["SUBSCRIPTION_STATE_PAUSED", "on_hold"],
      ["SUBSCRIPTION_STATE_PENDING", "on_hold"],
      // A family who turns off auto-renew: Play reports CANCELED, not ACTIVE, and the paid period still
      // runs. "Canceled but not expired yet" is Google's own definition — mapping it to `revoked` would cut
      // them off at the moment they cancelled (#684 review).
      ["SUBSCRIPTION_STATE_CANCELED", "active"],
      ["SUBSCRIPTION_STATE_EXPIRED", "expired"],
    ];
    for (const [apiState, state] of cases) {
      expect(normaliseSubscriptionPurchase(subscriptionBody({ subscriptionState: apiState }), "t").state, apiState).toBe(state);
    }
  });

  it("refuses a state or shape it does not recognise instead of guessing", () => {
    expect(() => normaliseSubscriptionPurchase(subscriptionBody({ subscriptionState: "SUBSCRIPTION_STATE_UNSPECIFIED" }), "t")).toThrow(PurchaseRejected);
    expect(() => normaliseSubscriptionPurchase(subscriptionBody({ subscriptionState: undefined }), "t")).toThrow(PurchaseRejected);
    expect(() => normaliseSubscriptionPurchase(subscriptionBody({ lineItems: [] }), "t")).toThrow(PurchaseRejected);
    expect(() => normaliseSubscriptionPurchase("not an object", "t")).toThrow(PurchaseRejected);
  });

  it("keeps the last expiring line item and tolerates a missing obfuscated id", () => {
    const purchase = normaliseSubscriptionPurchase(
      subscriptionBody({
        externalAccountIdentifiers: {},
        lineItems: [
          { productId: PRODUCT, expiryTime: "2026-12-13T00:00:00.000Z", autoRenewingPlan: { autoRenewEnabled: false } },
          { productId: PRODUCT, expiryTime: "2027-01-13T00:00:00.000Z", autoRenewingPlan: { autoRenewEnabled: true } },
        ],
      }),
      "t",
    );
    expect(purchase.expiryTime).toBe("2027-01-13T00:00:00.000Z");
    expect(purchase.familyIdFromObfuscatedAccountId).toBeNull();
    // One line item still renewing is enough for the purchase to renew.
    expect(purchase.autoRenews).toBe(true);
    expect(() => assertPurchaseBelongsToFamily("acct-fam-1", purchase)).toThrow(PurchaseAlreadyOwned);
  });

  it("reports a cancelled-but-paid purchase as active without renewal, never as revoked", () => {
    // What Play actually returns after a user turns off auto-renew: CANCELED, still entitled to the
    // period's end. `ACTIVE` is defined as at least one line item renewing, so it is not what arrives here
    // — using it as the fixture was the mistake this row exists to catch (#684 review).
    const purchase = normaliseSubscriptionPurchase(
      subscriptionBody({
        subscriptionState: "SUBSCRIPTION_STATE_CANCELED",
        lineItems: [{ productId: PRODUCT, expiryTime: "2026-12-13T00:00:00.000Z", autoRenewingPlan: { autoRenewEnabled: false } }],
      }),
      "t",
    );
    expect(purchase.state).toBe("active");
    expect(purchase.state).not.toBe("revoked");
    expect(purchase.autoRenews).toBe(false);
    expect(purchase.expiryTime).toBe("2026-12-13T00:00:00.000Z");
  });
});

describe("service-account access tokens", () => {
  const { privateKey } = generateKeyPairSync("rsa", { modulusLength: 2048 });
  const serviceAccountJson = JSON.stringify({
    type: "service_account",
    client_email: "billing@synthetic.invalid",
    private_key: privateKey.export({ type: "pkcs8", format: "pem" }).toString(),
    token_uri: "https://oauth.example.invalid/token",
  });

  it("exchanges the key for a bearer token once and reuses it", async () => {
    const calls: Array<{ url: string; init: RequestInit }> = [];
    let clock = 1_700_000_000_000;
    const provider = createServiceAccountTokenProvider(serviceAccountJson, {
      now: () => clock,
      transport: async (url, init) => {
        calls.push({ url, init });
        return jsonResponse({ access_token: "minted-token", expires_in: 3600 });
      },
    });

    expect(await provider()).toBe("minted-token");
    expect(await provider()).toBe("minted-token");
    expect(calls).toHaveLength(1);

    const form = new URLSearchParams(String(calls[0].init.body));
    expect(calls[0].url).toBe("https://oauth.example.invalid/token");
    expect(form.get("grant_type")).toBe("urn:ietf:params:oauth:grant-type:jwt-bearer");
    const claims = JSON.parse(Buffer.from(form.get("assertion")!.split(".")[1], "base64url").toString("utf8"));
    expect(claims).toMatchObject({ iss: "billing@synthetic.invalid", scope: "https://www.googleapis.com/auth/androidpublisher" });

    // A minute before expiry the provider mints a new one rather than sending a dying token.
    clock += 3600_000;
    await provider();
    expect(calls).toHaveLength(2);
  });

  it("refuses an unreadable key", async () => {
    const provider = createServiceAccountTokenProvider("not json");
    await expect(provider()).rejects.toBeInstanceOf(PlayUnavailable);
  });
});

describe("the Pub/Sub notification payload", () => {
  it("decodes base64 into a developer notification", () => {
    const data = Buffer.from(JSON.stringify({ packageName: PACKAGE, subscriptionNotification: { notificationType: 2, purchaseToken: "t" } })).toString("base64");
    expect(decodeNotification(data)).toMatchObject({ packageName: PACKAGE, subscriptionNotification: { notificationType: 2, purchaseToken: "t" } });
  });

  it("refuses data that is not a notification", () => {
    expect(() => decodeNotification(Buffer.from("hello").toString("base64"))).toThrow(MalformedNotification);
    expect(() => decodeNotification(Buffer.from(JSON.stringify({ subscriptionNotification: {} })).toString("base64"))).toThrow(MalformedNotification);
  });
});

describe("the Pub/Sub OIDC verifier", () => {
  const NOW = Date.parse("2026-11-13T10:00:00.000Z");
  const audience = "https://api.osratech.invalid/v1/billing/google/rtdn";
  const email = "push@synthetic.invalid";
  const { privateKey, publicKey } = generateKeyPairSync("rsa", { modulusLength: 2048 });
  const other = generateKeyPairSync("rsa", { modulusLength: 2048 });
  const jwk = publicKey.export({ format: "jwk" }) as { kty: string; n: string; e: string };

  function signToken(payload: Record<string, unknown>, options: { kid?: string; key?: typeof privateKey; header?: Record<string, unknown> } = {}): string {
    const encode = (value: unknown) => Buffer.from(JSON.stringify(value)).toString("base64url");
    const unsigned = `${encode({ alg: "RS256", typ: "JWT", kid: options.kid ?? "kid-1", ...options.header })}.${encode(payload)}`;
    const signer = createSign("RSA-SHA256");
    signer.update(unsigned);
    signer.end();
    return `${unsigned}.${signer.sign(options.key ?? privateKey).toString("base64url")}`;
  }

  const payload = (overrides: Record<string, unknown> = {}) => ({
    iss: "https://accounts.google.com",
    aud: audience,
    email,
    email_verified: true,
    sub: "100000000000000000001",
    iat: Math.floor(NOW / 1000) - 30,
    exp: Math.floor(NOW / 1000) + 3600,
    ...overrides,
  });

  function verifier(overrides: { certs?: unknown; transport?: (url: string, init: RequestInit) => Promise<Response> } = {}) {
    const transport = vi.fn(overrides.transport ?? (async () => jsonResponse(overrides.certs ?? { keys: [{ ...jwk, kid: "kid-1", alg: "RS256", use: "sig" }] })));
    return {
      verify: createGoogleOidcVerifier({ audience, serviceAccountEmail: email, transport, now: () => NOW }),
      transport,
    };
  }

  it("accepts a token Google signed for this audience and signer", async () => {
    const { verify, transport } = verifier();
    const identity = await verify(signToken(payload()));
    expect(identity).toMatchObject({ email, issuer: "https://accounts.google.com" });
    // The certificate set is cached: a second push does not refetch it.
    await verify(signToken(payload()));
    expect(transport).toHaveBeenCalledTimes(1);
  });

  it("refuses a token signed by anyone else", async () => {
    const { verify } = verifier();
    await expect(verify(signToken(payload(), { key: other.privateKey }))).rejects.toBeInstanceOf(OidcRejected);
  });

  it("refuses the wrong audience, signer and issuer", async () => {
    const { verify } = verifier();
    await expect(verify(signToken(payload({ aud: "https://other.invalid" })))).rejects.toBeInstanceOf(OidcRejected);
    await expect(verify(signToken(payload({ email: "someone@synthetic.invalid" })))).rejects.toBeInstanceOf(OidcRejected);
    await expect(verify(signToken(payload({ iss: "https://evil.invalid" })))).rejects.toBeInstanceOf(OidcRejected);
  });

  it("refuses an expired token, an unsigned one, and an unknown key id", async () => {
    const { verify } = verifier();
    await expect(verify(signToken(payload({ exp: Math.floor(NOW / 1000) - 600 })))).rejects.toBeInstanceOf(OidcRejected);
    await expect(verify(signToken(payload(), { header: { alg: "none" } }))).rejects.toBeInstanceOf(OidcRejected);
    await expect(verify(signToken(payload(), { kid: "kid-unknown" }))).rejects.toBeInstanceOf(OidcRejected);
    await expect(verify("not-a-jwt")).rejects.toBeInstanceOf(OidcRejected);
  });

  it("refuses when the certificate set cannot be fetched", async () => {
    const { verify } = verifier({ transport: async () => jsonResponse({}, 500) });
    await expect(verify(signToken(payload()))).rejects.toBeInstanceOf(OidcRejected);
  });
});
