import { beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import { authHeader, buildApp, deviceHeader, prismaMock, resetPrismaMock } from "./helpers.js";

vi.mock("../src/db.js", () => ({ prisma: prismaMock }));
vi.mock("../src/redis.js", async () => {
  const { MockRedis } = await import("./helpers.js");
  const redis = new MockRedis();
  return {
    getRedis: () => redis,
    setJsonNx: vi.fn(async () => true),
    publishJson: vi.fn(async () => undefined),
  };
});

import {
  findFamilyForPurchase,
  grantEntitlement,
  setEntitlementStore,
  type EntitlementChange,
  type EntitlementStore,
} from "../src/lib/entitlement.js";
import {
  obfuscatedAccountIdFor,
  PlayUnavailable,
  PurchaseRejected,
  type PlayClient,
  type VerifiedPurchase,
} from "../src/lib/billing/google.js";
import {
  OidcRejected,
  createMemorySeenMessages,
  mapNotificationType,
  type OidcVerifier,
} from "../src/lib/billing/rtdn.js";
import { billingRoutes, type BillingDeps } from "../src/routes/billing.js";

const PRODUCT = "com.osratech.family.monthly";
const TOKEN = "play-purchase-token-1";

/** A store that records what the routes asked for, and binds purchases the way the real one will. */
function recordingStore(): EntitlementStore & {
  grant: ReturnType<typeof vi.fn>;
  revoke: ReturnType<typeof vi.fn>;
  findFamily: ReturnType<typeof vi.fn>;
} {
  const bindings = new Map<string, string>();
  const remember = (change: EntitlementChange) => bindings.set(`${change.source}:${change.externalId}`, change.familyId);
  return {
    grant: vi.fn(async (change: EntitlementChange) => remember(change)),
    revoke: vi.fn(async (change: EntitlementChange) => remember(change)),
    findFamily: vi.fn(async (source: string, externalId: string) => bindings.get(`${source}:${externalId}`) ?? null),
  } as unknown as EntitlementStore & {
    grant: ReturnType<typeof vi.fn>;
    revoke: ReturnType<typeof vi.fn>;
    findFamily: ReturnType<typeof vi.fn>;
  };
}

function fakePlay(overrides: Partial<PlayClient> = {}): PlayClient & {
  verifySubscription: ReturnType<typeof vi.fn>;
  acknowledgeSubscription: ReturnType<typeof vi.fn>;
} {
  return {
    verifySubscription: vi.fn(async () => verified()),
    acknowledgeSubscription: vi.fn(async () => undefined),
    ...overrides,
  } as unknown as PlayClient & {
    verifySubscription: ReturnType<typeof vi.fn>;
    acknowledgeSubscription: ReturnType<typeof vi.fn>;
  };
}

function verified(overrides: Partial<VerifiedPurchase> = {}): VerifiedPurchase {
  return {
    familyIdFromObfuscatedAccountId: obfuscatedAccountIdFor("fam-1"),
    state: "active",
    externalId: TOKEN,
    expiryTime: "2026-12-13T00:00:00.000Z",
    productId: PRODUCT,
    acknowledgementState: "pending",
    ...overrides,
  };
}

const pushVerifier: OidcVerifier = async (token: string) => {
  if (token !== "good-push-token") throw new OidcRejected("bad_signature");
  return { email: "push@synthetic.invalid", subject: "123", issuer: "https://accounts.google.com" };
};

function deps(overrides: BillingDeps = {}): BillingDeps {
  return {
    play: fakePlay(),
    verifyPushToken: pushVerifier,
    seen: createMemorySeenMessages(),
    log: vi.fn(),
    ...overrides,
  };
}

beforeAll(() => {
  process.env.BILLING_ACCOUNT_ID_KEY = "test-account-id-key";
});

beforeEach(() => {
  resetPrismaMock();
  setEntitlementStore(null);
});

describe("entitlement seam (the only way billing reaches the plan)", () => {
  it("records a grant and answers the purchase's family", async () => {
    await grantEntitlement({
      familyId: "fam-1",
      source: "google",
      state: "active",
      externalId: TOKEN,
      effectiveAt: "2026-11-13T00:00:00Z",
      cause: "verify",
    });
    expect(await findFamilyForPurchase("google", TOKEN)).toBe("fam-1");
    // The binding is per source: the same reference means nothing on another store.
    expect(await findFamilyForPurchase("apple", TOKEN)).toBeNull();
  });

  it("forgets the old store when a new one is set", async () => {
    await grantEntitlement({ familyId: "fam-1", source: "google", state: "active", externalId: TOKEN, effectiveAt: "2026-11-13T00:00:00Z", cause: "verify" });
    setEntitlementStore(null);
    expect(await findFamilyForPurchase("google", TOKEN)).toBeNull();
  });
});

describe("POST /v1/billing/google/verify", () => {
  it("grants the plan for a verified purchase and returns its state", async () => {
    const store = recordingStore();
    setEntitlementStore(store);
    const play = fakePlay();
    const app = await buildApp((a) => billingRoutes(a, deps({ play })), "/v1/billing");

    const res = await app.inject({
      method: "POST",
      url: "/v1/billing/google/verify",
      headers: authHeader(app),
      payload: { purchaseToken: TOKEN, productId: PRODUCT },
    });

    expect(res.statusCode).toBe(200);
    expect(res.json()).toEqual({ state: "active", source: "google", productId: PRODUCT, expiryTime: "2026-12-13T00:00:00.000Z" });
    expect(store.grant).toHaveBeenCalledTimes(1);
    expect(store.grant.mock.calls[0][0]).toMatchObject({
      familyId: "fam-1",
      source: "google",
      state: "active",
      externalId: TOKEN,
      cause: "verify",
    });
    expect(store.revoke).not.toHaveBeenCalled();
    expect(play.acknowledgeSubscription).toHaveBeenCalledWith(TOKEN, PRODUCT);
    await app.close();
  });

  it("refuses a purchase bound to another family's obfuscated account id", async () => {
    const store = recordingStore();
    setEntitlementStore(store);
    const play = fakePlay({
      verifySubscription: vi.fn(async () => verified({ familyIdFromObfuscatedAccountId: obfuscatedAccountIdFor("fam-2") })),
    });
    const app = await buildApp((a) => billingRoutes(a, deps({ play })), "/v1/billing");

    const res = await app.inject({
      method: "POST",
      url: "/v1/billing/google/verify",
      headers: authHeader(app),
      payload: { purchaseToken: TOKEN, productId: PRODUCT },
    });

    expect(res.statusCode).toBe(403);
    expect(res.json()).toEqual({ error: "purchase_owned_by_another_family" });
    expect(store.grant).not.toHaveBeenCalled();
    expect(store.revoke).not.toHaveBeenCalled();
    // A purchase we refused is not acknowledged either: acknowledging is telling Play we delivered it.
    expect(play.acknowledgeSubscription).not.toHaveBeenCalled();
    await app.close();
  });

  it("refuses a purchase that carries no obfuscated account id at all", async () => {
    const store = recordingStore();
    setEntitlementStore(store);
    const play = fakePlay({ verifySubscription: vi.fn(async () => verified({ familyIdFromObfuscatedAccountId: null })) });
    const app = await buildApp((a) => billingRoutes(a, deps({ play })), "/v1/billing");

    const res = await app.inject({
      method: "POST",
      url: "/v1/billing/google/verify",
      headers: authHeader(app),
      payload: { purchaseToken: TOKEN, productId: PRODUCT },
    });

    expect(res.statusCode).toBe(403);
    expect(res.json()).toEqual({ error: "purchase_owned_by_another_family" });
    expect(store.grant).not.toHaveBeenCalled();
    await app.close();
  });

  it("answers 400 for a forged, spent or unreadable token", async () => {
    const store = recordingStore();
    setEntitlementStore(store);
    const play = fakePlay({
      verifySubscription: vi.fn(async () => {
        throw new PurchaseRejected("verify_status_404");
      }),
    });
    const app = await buildApp((a) => billingRoutes(a, deps({ play })), "/v1/billing");

    const res = await app.inject({
      method: "POST",
      url: "/v1/billing/google/verify",
      headers: authHeader(app),
      payload: { purchaseToken: "forged", productId: PRODUCT },
    });

    expect(res.statusCode).toBe(400);
    expect(res.json()).toEqual({ error: "purchase_rejected" });
    expect(store.grant).not.toHaveBeenCalled();
    await app.close();
  });

  it("answers 503 when Play itself is unavailable", async () => {
    const store = recordingStore();
    setEntitlementStore(store);
    const play = fakePlay({
      verifySubscription: vi.fn(async () => {
        throw new PlayUnavailable("transport:ECONNRESET");
      }),
    });
    const app = await buildApp((a) => billingRoutes(a, deps({ play })), "/v1/billing");

    const res = await app.inject({
      method: "POST",
      url: "/v1/billing/google/verify",
      headers: authHeader(app),
      payload: { purchaseToken: TOKEN, productId: PRODUCT },
    });

    expect(res.statusCode).toBe(503);
    expect(res.json()).toEqual({ error: "play_unavailable" });
    expect(store.grant).not.toHaveBeenCalled();
    await app.close();
  });

  it("answers 503, not 500, when the deployment has no Play credentials", async () => {
    const store = recordingStore();
    setEntitlementStore(store);
    const log = vi.fn();
    const app = await buildApp((a) => billingRoutes(a, deps({ play: null, log })), "/v1/billing");

    const res = await app.inject({
      method: "POST",
      url: "/v1/billing/google/verify",
      headers: authHeader(app),
      payload: { purchaseToken: TOKEN, productId: PRODUCT },
    });

    expect(res.statusCode).toBe(503);
    expect(res.json()).toEqual({ error: "play_unavailable" });
    expect(store.grant).not.toHaveBeenCalled();
    await app.close();
  });

  it("refuses a body whose productId is not the purchase's", async () => {
    const store = recordingStore();
    setEntitlementStore(store);
    const app = await buildApp((a) => billingRoutes(a, deps()), "/v1/billing");

    const res = await app.inject({
      method: "POST",
      url: "/v1/billing/google/verify",
      headers: authHeader(app),
      payload: { purchaseToken: TOKEN, productId: "com.osratech.family.yearly" },
    });

    expect(res.statusCode).toBe(400);
    expect(res.json()).toEqual({ error: "purchase_rejected" });
    expect(store.grant).not.toHaveBeenCalled();
    await app.close();
  });

  it("revokes rather than grants when the purchase has already expired", async () => {
    const store = recordingStore();
    setEntitlementStore(store);
    const play = fakePlay({ verifySubscription: vi.fn(async () => verified({ state: "expired" })) });
    const app = await buildApp((a) => billingRoutes(a, deps({ play })), "/v1/billing");

    const res = await app.inject({
      method: "POST",
      url: "/v1/billing/google/verify",
      headers: authHeader(app),
      payload: { purchaseToken: TOKEN, productId: PRODUCT },
    });

    expect(res.statusCode).toBe(200);
    expect(res.json()).toMatchObject({ state: "expired" });
    expect(store.grant).not.toHaveBeenCalled();
    expect(store.revoke).toHaveBeenCalledTimes(1);
    expect(store.revoke.mock.calls[0][0]).toMatchObject({ state: "expired", cause: "verify" });
    await app.close();
  });

  it("keeps the plan when Play refuses the acknowledgement", async () => {
    const store = recordingStore();
    setEntitlementStore(store);
    const log = vi.fn();
    const play = fakePlay({
      acknowledgeSubscription: vi.fn(async () => {
        throw new PlayUnavailable("acknowledge_status_503");
      }),
    });
    const app = await buildApp((a) => billingRoutes(a, deps({ play, log })), "/v1/billing");

    const res = await app.inject({
      method: "POST",
      url: "/v1/billing/google/verify",
      headers: authHeader(app),
      payload: { purchaseToken: TOKEN, productId: PRODUCT },
    });

    expect(res.statusCode).toBe(200);
    expect(store.grant).toHaveBeenCalledTimes(1);
    expect(log).toHaveBeenCalledWith("billing.verify.acknowledge_failed", expect.objectContaining({ productId: PRODUCT }));
    await app.close();
  });

  it("does not acknowledge a purchase Play already shows as acknowledged", async () => {
    const play = fakePlay({ verifySubscription: vi.fn(async () => verified({ acknowledgementState: "acknowledged" })) });
    const app = await buildApp((a) => billingRoutes(a, deps({ play })), "/v1/billing");

    const res = await app.inject({
      method: "POST",
      url: "/v1/billing/google/verify",
      headers: authHeader(app),
      payload: { purchaseToken: TOKEN, productId: PRODUCT },
    });

    expect(res.statusCode).toBe(200);
    expect(play.acknowledgeSubscription).not.toHaveBeenCalled();
    await app.close();
  });

  it("refuses without a parent session, and refuses a device token", async () => {
    const app = await buildApp((a) => billingRoutes(a, deps()), "/v1/billing");

    const anonymous = await app.inject({
      method: "POST",
      url: "/v1/billing/google/verify",
      payload: { purchaseToken: TOKEN, productId: PRODUCT },
    });
    const device = await app.inject({
      method: "POST",
      url: "/v1/billing/google/verify",
      headers: deviceHeader(app),
      payload: { purchaseToken: TOKEN, productId: PRODUCT },
    });

    expect(anonymous.statusCode).toBe(401);
    expect(device.statusCode).toBe(403);
    expect(device.json()).toEqual({ error: "parent_role_required" });
    await app.close();
  });

  it("refuses a stale token whose family claim is not the parent's current family", async () => {
    const store = recordingStore();
    setEntitlementStore(store);
    const play = fakePlay();
    const app = await buildApp((a) => billingRoutes(a, deps({ play })), "/v1/billing");

    const res = await app.inject({
      method: "POST",
      url: "/v1/billing/google/verify",
      headers: authHeader(app, "fam-2"),
      payload: { purchaseToken: TOKEN, productId: PRODUCT },
    });

    expect(res.statusCode).toBe(403);
    expect(play.verifySubscription).not.toHaveBeenCalled();
    expect(store.grant).not.toHaveBeenCalled();
    await app.close();
  });

  it("rejects a malformed body", async () => {
    const app = await buildApp((a) => billingRoutes(a, deps()), "/v1/billing");
    const res = await app.inject({
      method: "POST",
      url: "/v1/billing/google/verify",
      headers: authHeader(app),
      payload: { productId: PRODUCT },
    });
    expect(res.statusCode).toBe(400);
    await app.close();
  });
});

function pushPayload(notification: unknown, messageId: string, token = "good-push-token") {
  return {
    headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
    payload: { message: { data: Buffer.from(JSON.stringify(notification)).toString("base64"), messageId } },
  };
}

function subscriptionNotification(notificationType: number, purchaseToken = TOKEN) {
  return {
    packageName: "com.osratech.parent",
    eventTimeMillis: String(Date.parse("2026-11-13T09:00:00Z")),
    subscriptionNotification: { version: "1.0", notificationType, purchaseToken, subscriptionId: PRODUCT },
  };
}

/** A family that verified this token once — the state every RTDN case starts from. */
async function bindPurchase(store: ReturnType<typeof recordingStore>, familyId = "fam-1"): Promise<void> {
  setEntitlementStore(store);
  await grantEntitlement({
    familyId,
    source: "google",
    state: "active",
    externalId: TOKEN,
    effectiveAt: "2026-11-01T00:00:00Z",
    cause: "verify",
  });
  store.grant.mockClear();
  store.revoke.mockClear();
}

describe("POST /v1/billing/google/rtdn", () => {
  it("applies a renewal as a grant with the notification's own timestamp", async () => {
    const store = recordingStore();
    await bindPurchase(store);
    const app = await buildApp((a) => billingRoutes(a, deps()), "/v1/billing");

    const res = await app.inject({ method: "POST", url: "/v1/billing/google/rtdn", ...pushPayload(subscriptionNotification(2), "msg-renewed") });

    expect(res.statusCode).toBe(204);
    expect(store.grant).toHaveBeenCalledTimes(1);
    expect(store.grant.mock.calls[0][0]).toMatchObject({
      familyId: "fam-1",
      source: "google",
      state: "active",
      externalId: TOKEN,
      cause: "renewed",
      effectiveAt: "2026-11-13T09:00:00.000Z",
    });
    expect(store.revoke).not.toHaveBeenCalled();
    await app.close();
  });

  it("revokes the plan on a cancellation", async () => {
    const store = recordingStore();
    await bindPurchase(store);
    const app = await buildApp((a) => billingRoutes(a, deps()), "/v1/billing");

    const res = await app.inject({ method: "POST", url: "/v1/billing/google/rtdn", ...pushPayload(subscriptionNotification(3), "msg-canceled") });

    expect(res.statusCode).toBe(204);
    expect(store.revoke).toHaveBeenCalledTimes(1);
    expect(store.revoke.mock.calls[0][0]).toMatchObject({ state: "revoked", cause: "canceled", familyId: "fam-1" });
    expect(store.grant).not.toHaveBeenCalled();
    await app.close();
  });

  it("ignores an unknown notification type and says why in the log", async () => {
    const store = recordingStore();
    await bindPurchase(store);
    const log = vi.fn();
    const app = await buildApp((a) => billingRoutes(a, deps({ log })), "/v1/billing");

    const res = await app.inject({ method: "POST", url: "/v1/billing/google/rtdn", ...pushPayload(subscriptionNotification(99), "msg-unknown") });

    expect(res.statusCode).toBe(204);
    expect(store.grant).not.toHaveBeenCalled();
    expect(store.revoke).not.toHaveBeenCalled();
    expect(log).toHaveBeenCalledWith("billing.rtdn.ignored", expect.objectContaining({ messageId: "msg-unknown", reason: "unknown_notification_type:99" }));
    await app.close();
  });

  it("ignores a price change, which moves no state, with its own reason", async () => {
    const store = recordingStore();
    await bindPurchase(store);
    const log = vi.fn();
    const app = await buildApp((a) => billingRoutes(a, deps({ log })), "/v1/billing");

    const res = await app.inject({ method: "POST", url: "/v1/billing/google/rtdn", ...pushPayload(subscriptionNotification(8), "msg-price") });

    expect(res.statusCode).toBe(204);
    expect(store.grant).not.toHaveBeenCalled();
    expect(log).toHaveBeenCalledWith("billing.rtdn.ignored", expect.objectContaining({ reason: "price_change_has_no_state_change" }));
    await app.close();
  });

  it("applies a duplicate messageId once, and logs the duplicate", async () => {
    const store = recordingStore();
    await bindPurchase(store);
    const log = vi.fn();
    const app = await buildApp((a) => billingRoutes(a, deps({ log })), "/v1/billing");
    const payload = pushPayload(subscriptionNotification(2), "msg-twice");

    const first = await app.inject({ method: "POST", url: "/v1/billing/google/rtdn", ...payload });
    const second = await app.inject({ method: "POST", url: "/v1/billing/google/rtdn", ...payload });

    expect(first.statusCode).toBe(204);
    expect(second.statusCode).toBe(204);
    expect(store.grant).toHaveBeenCalledTimes(1);
    expect(log).toHaveBeenCalledWith("billing.rtdn.duplicate", expect.objectContaining({ messageId: "msg-twice" }));
    await app.close();
  });

  it("refuses an unverified push token and touches nothing", async () => {
    const store = recordingStore();
    await bindPurchase(store);
    const app = await buildApp((a) => billingRoutes(a, deps()), "/v1/billing");

    const res = await app.inject({ method: "POST", url: "/v1/billing/google/rtdn", ...pushPayload(subscriptionNotification(3), "msg-forged", "forged-token") });

    expect(res.statusCode).toBe(401);
    expect(res.json()).toEqual({ error: "invalid_push_token" });
    expect(store.revoke).not.toHaveBeenCalled();
    await app.close();
  });

  it("refuses a push with no authorization header", async () => {
    const app = await buildApp((a) => billingRoutes(a, deps()), "/v1/billing");
    const res = await app.inject({
      method: "POST",
      url: "/v1/billing/google/rtdn",
      payload: { message: { data: "e30=", messageId: "msg-anon" } },
    });
    expect(res.statusCode).toBe(401);
    await app.close();
  });

  it("answers 503 when RTDN has no verifier configured, so Pub/Sub keeps the message", async () => {
    const app = await buildApp((a) => billingRoutes(a, { play: null, log: vi.fn() }), "/v1/billing");
    const res = await app.inject({ method: "POST", url: "/v1/billing/google/rtdn", ...pushPayload(subscriptionNotification(2), "msg-noenv") });
    expect(res.statusCode).toBe(503);
    await app.close();
  });

  it("answers 400 for a malformed envelope and for data that is not a notification", async () => {
    const app = await buildApp((a) => billingRoutes(a, deps()), "/v1/billing");

    const noMessage = await app.inject({
      method: "POST",
      url: "/v1/billing/google/rtdn",
      headers: { authorization: "Bearer good-push-token" },
      payload: { message: { messageId: "x" } },
    });
    const notJson = await app.inject({
      method: "POST",
      url: "/v1/billing/google/rtdn",
      headers: { authorization: "Bearer good-push-token" },
      payload: { message: { data: Buffer.from("not json").toString("base64"), messageId: "msg-bad-json" } },
    });

    expect(noMessage.statusCode).toBe(400);
    expect(notJson.statusCode).toBe(400);
    expect(notJson.json()).toEqual({ error: "malformed_notification" });
    await app.close();
  });

  it("acknowledges a test notification without touching the plan", async () => {
    const store = recordingStore();
    setEntitlementStore(store);
    const log = vi.fn();
    const app = await buildApp((a) => billingRoutes(a, deps({ log })), "/v1/billing");

    const res = await app.inject({
      method: "POST",
      url: "/v1/billing/google/rtdn",
      ...pushPayload({ packageName: "com.osratech.parent", testNotification: { version: "1.0" } }, "msg-test"),
    });

    expect(res.statusCode).toBe(204);
    expect(store.grant).not.toHaveBeenCalled();
    expect(log).toHaveBeenCalledWith("billing.rtdn.no_subscription", expect.objectContaining({ messageId: "msg-test" }));
    await app.close();
  });

  it("acknowledges a notification for a purchase it has never stored, and logs the miss", async () => {
    const store = recordingStore();
    setEntitlementStore(store);
    const log = vi.fn();
    const app = await buildApp((a) => billingRoutes(a, deps({ log })), "/v1/billing");

    const res = await app.inject({ method: "POST", url: "/v1/billing/google/rtdn", ...pushPayload(subscriptionNotification(2, "tok-never-verified"), "msg-stranger") });

    expect(res.statusCode).toBe(204);
    expect(store.grant).not.toHaveBeenCalled();
    expect(log).toHaveBeenCalledWith("billing.rtdn.unknown_purchase", expect.objectContaining({ messageId: "msg-stranger", type: "renewed" }));
    await app.close();
  });

  it("hands the claim back when the store fails, so the retry can still land", async () => {
    const store = recordingStore();
    await bindPurchase(store);
    store.grant.mockRejectedValueOnce(new Error("store down"));
    const app = await buildApp((a) => billingRoutes(a, deps()), "/v1/billing");
    const payload = pushPayload(subscriptionNotification(2), "msg-retry");

    const failed = await app.inject({ method: "POST", url: "/v1/billing/google/rtdn", ...payload });
    const retried = await app.inject({ method: "POST", url: "/v1/billing/google/rtdn", ...payload });

    expect(failed.statusCode).toBe(503);
    expect(retried.statusCode).toBe(204);
    // The first attempt reached the store and threw; the retry reached it again and landed, which can
    // only happen if the claim was released instead of swallowed.
    expect(store.grant).toHaveBeenCalledTimes(2);
    expect(store.grant.mock.results[0].type).toBe("throw");
    expect(store.grant.mock.results[1].type).toBe("return");
    await app.close();
  });

  it("maps every known notification type to a state and a cause", async () => {
    const expected: Array<[number, string, string]> = [
      [1, "active", "recovered"],
      [2, "active", "renewed"],
      [3, "revoked", "canceled"],
      [4, "active", "purchased"],
      [5, "on_hold", "on_hold"],
      [6, "grace", "in_grace"],
      [7, "active", "restarted"],
      [10, "on_hold", "paused"],
      [12, "revoked", "revoked"],
      [13, "expired", "expired"],
    ];
    for (const [type, state, cause] of expected) {
      const mapping = mapNotificationType(type);
      expect(mapping, `type ${type}`).toEqual({ kind: "change", state, cause, typeName: expect.any(String) });
    }
    expect(mapNotificationType(8)).toMatchObject({ kind: "ignored", reason: "price_change_has_no_state_change" });
    expect(mapNotificationType(undefined)).toMatchObject({ kind: "ignored", reason: "missing_notification_type" });
    expect(mapNotificationType(999)).toMatchObject({ kind: "ignored", reason: "unknown_notification_type:999" });
  });
});
