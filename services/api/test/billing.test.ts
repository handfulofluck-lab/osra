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
  hashStoreRef,
  setEntitlementStore,
  storeAccountIdFor,
  type EntitlementGrant,
  type EntitlementRevocation,
  type EntitlementStore,
} from "../src/lib/entitlement.js";
import {
  PlayUnavailable,
  PurchaseRejected,
  type PlayClient,
  type VerifiedPurchase,
} from "../src/lib/billing/google.js";
import {
  OidcRejected,
  createMemorySeenMessages,
  notificationCause,
  type OidcVerifier,
} from "../src/lib/billing/rtdn.js";
import { billingRoutes, type BillingDeps } from "../src/routes/billing.js";

const PRODUCT = "com.osratech.family.monthly";
const TOKEN = "play-purchase-token-1";
/** What the recording store hands back for `fam-1`; the fixture purchase echoes it. */
const ACCOUNT_ID = "acct-fam-1";

/** A store that records what the routes asked for, and binds purchases the way the real one will. */
function recordingStore() {
  const bindings = new Map<string, string>();
  const accountIds = new Map<string, string>();
  const remember = (change: EntitlementGrant | EntitlementRevocation) =>
    bindings.set(`${change.source}:${hashStoreRef(change.storeRef)}`, change.familyId);
  return {
    grant: vi.fn(async (change: EntitlementGrant) => remember(change)),
    revoke: vi.fn(async (change: EntitlementRevocation) => remember(change)),
    findFamily: vi.fn(async (source: string, storeRef: string) => bindings.get(`${source}:${hashStoreRef(storeRef)}`) ?? null),
    storeAccountId: vi.fn(async (familyId: string) => {
      const existing = accountIds.get(familyId);
      if (existing) return existing;
      const created = `acct-${familyId}`;
      accountIds.set(familyId, created);
      return created;
    }),
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
    familyIdFromObfuscatedAccountId: ACCOUNT_ID,
    state: "active",
    storeRef: TOKEN,
    expiryTime: "2026-12-13T00:00:00.000Z",
    productId: PRODUCT,
    autoRenews: true,
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

function pushPayload(notification: unknown, messageId: string, token = "good-push-token") {
  return {
    headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
    payload: { message: { data: Buffer.from(JSON.stringify(notification)).toString("base64"), messageId } },
  };
}

function subscriptionNotification(notificationType: number, purchaseToken = TOKEN, eventTime = "2026-11-12T09:00:00Z") {
  return {
    packageName: "com.osratech.parent",
    eventTimeMillis: String(Date.parse(eventTime)),
    subscriptionNotification: { version: "1.0", notificationType, purchaseToken, subscriptionId: PRODUCT },
  };
}

/** A family that verified this token once — the state every RTDN case starts from. */
async function bindPurchase(store: ReturnType<typeof recordingStore>, familyId = "fam-1"): Promise<void> {
  setEntitlementStore(store as unknown as EntitlementStore);
  await grantEntitlement({
    familyId,
    source: "google_play",
    state: "active",
    productId: PRODUCT,
    expiresAt: "2026-12-13T00:00:00.000Z",
    autoRenews: true,
    storeRef: TOKEN,
    effectiveAt: "2026-11-01T00:00:00Z",
    cause: "verify",
  });
  store.grant.mockClear();
  store.revoke.mockClear();
  store.findFamily.mockClear();
}

beforeAll(() => {
  process.env.JWT_SECRET = "test-only-secret";
});

beforeEach(() => {
  resetPrismaMock();
  setEntitlementStore(null);
});

describe("entitlement seam (the only way billing reaches the plan)", () => {
  it("records a grant and answers the purchase's family", async () => {
    await grantEntitlement({
      familyId: "fam-1",
      source: "google_play",
      state: "active",
      productId: PRODUCT,
      expiresAt: "2026-12-13T00:00:00Z",
      autoRenews: true,
      storeRef: TOKEN,
      effectiveAt: "2026-11-13T00:00:00Z",
      cause: "verify",
    });
    expect(await findFamilyForPurchase("google_play", TOKEN)).toBe("fam-1");
    // The binding is per source: the same reference means nothing on another store.
    expect(await findFamilyForPurchase("app_store", TOKEN)).toBeNull();
  });

  it("stores a hash of the store reference, never the reference", async () => {
    const hash = hashStoreRef(TOKEN);
    expect(hash).toMatch(/^[0-9a-f]{64}$/);
    expect(hash).not.toContain(TOKEN);
    expect(hashStoreRef(TOKEN)).toBe(hash);
  });

  it("forgets the old store when a new one is set", async () => {
    await grantEntitlement({ familyId: "fam-1", source: "google_play", state: "active", productId: PRODUCT, expiresAt: "2026-12-13T00:00:00Z", autoRenews: true, storeRef: TOKEN, effectiveAt: "2026-11-13T00:00:00Z", cause: "verify" });
    setEntitlementStore(null);
    expect(await findFamilyForPurchase("google_play", TOKEN)).toBeNull();
  });

  it("hands out one opaque account id per family, created on first use", async () => {
    const first = await storeAccountIdFor("fam-1");
    expect(first).toMatch(/^[0-9a-f]{32}$/);
    expect(await storeAccountIdFor("fam-1")).toBe(first);
    expect(await storeAccountIdFor("fam-2")).not.toBe(first);
    // Opaque: nothing in the id says which family it belongs to.
    expect(first).not.toContain("fam-1");
  });
});

describe("POST /v1/billing/google/verify", () => {
  it("grants the plan for a verified purchase and returns its state", async () => {
    const store = recordingStore();
    setEntitlementStore(store as unknown as EntitlementStore);
    const play = fakePlay();
    const app = await buildApp((a) => billingRoutes(a, deps({ play })), "/v1/billing");

    const res = await app.inject({
      method: "POST",
      url: "/v1/billing/google/verify",
      headers: authHeader(app),
      payload: { purchaseToken: TOKEN, productId: PRODUCT },
    });

    expect(res.statusCode).toBe(200);
    expect(res.json()).toEqual({
      state: "active",
      source: "google_play",
      productId: PRODUCT,
      expiresAt: "2026-12-13T00:00:00.000Z",
      autoRenews: true,
    });
    expect(store.grant).toHaveBeenCalledTimes(1);
    expect(store.grant.mock.calls[0][0]).toMatchObject({
      familyId: "fam-1",
      source: "google_play",
      state: "active",
      productId: PRODUCT,
      expiresAt: "2026-12-13T00:00:00.000Z",
      autoRenews: true,
      storeRef: TOKEN,
      cause: "verify",
    });
    expect(store.revoke).not.toHaveBeenCalled();
    expect(play.acknowledgeSubscription).toHaveBeenCalledWith(TOKEN, PRODUCT);
    await app.close();
  });

  it("refuses a purchase bound to another family's account id", async () => {
    const store = recordingStore();
    setEntitlementStore(store as unknown as EntitlementStore);
    const play = fakePlay({ verifySubscription: vi.fn(async () => verified({ familyIdFromObfuscatedAccountId: "acct-fam-2" })) });
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

  it("refuses a purchase that carries no account id at all", async () => {
    const store = recordingStore();
    setEntitlementStore(store as unknown as EntitlementStore);
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
    setEntitlementStore(store as unknown as EntitlementStore);
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
    setEntitlementStore(store as unknown as EntitlementStore);
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
    setEntitlementStore(store as unknown as EntitlementStore);
    const app = await buildApp((a) => billingRoutes(a, deps({ play: null })), "/v1/billing");

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
    setEntitlementStore(store as unknown as EntitlementStore);
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
    setEntitlementStore(store as unknown as EntitlementStore);
    const play = fakePlay({ verifySubscription: vi.fn(async () => verified({ state: "expired", autoRenews: false })) });
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
    setEntitlementStore(store as unknown as EntitlementStore);
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

  it("acknowledges a purchase that a push finds still pending", async () => {
    const store = recordingStore();
    setEntitlementStore(store as unknown as EntitlementStore);
    const log = vi.fn();
    const play = fakePlay();
    // `/verify` cannot reach Play's acknowledge endpoint; the purchase is still pending afterwards.
    play.acknowledgeSubscription.mockRejectedValueOnce(new PlayUnavailable("acknowledge_status_503"));
    const app = await buildApp((a) => billingRoutes(a, deps({ play, log })), "/v1/billing");

    const verifiedRes = await app.inject({
      method: "POST",
      url: "/v1/billing/google/verify",
      headers: authHeader(app),
      payload: { purchaseToken: TOKEN, productId: PRODUCT },
    });
    expect(verifiedRes.statusCode).toBe(200);

    const pushRes = await app.inject({
      method: "POST",
      url: "/v1/billing/google/rtdn",
      ...pushPayload(subscriptionNotification(4), "msg-ack-retry"),
    });

    expect(pushRes.statusCode).toBe(204);
    expect(play.acknowledgeSubscription).toHaveBeenCalledTimes(2);
    expect(log).toHaveBeenCalledWith("billing.rtdn.acknowledged", expect.objectContaining({ productId: PRODUCT }));
    await app.close();
  });

  it("does not acknowledge a purchase Play already shows as acknowledged", async () => {
    const store = recordingStore();
    setEntitlementStore(store as unknown as EntitlementStore);
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

  it("refuses a co-parent: only the family owner buys (ADR-0014, D1)", async () => {
    const store = recordingStore();
    setEntitlementStore(store as unknown as EntitlementStore);
    prismaMock.parent.findUnique.mockResolvedValue({
      id: "parent-1", familyId: "fam-1", role: "co-parent", permissions: ["devices"], mfaEnabled: false, mfaSecret: null,
    });
    const play = fakePlay();
    const app = await buildApp((a) => billingRoutes(a, deps({ play })), "/v1/billing");

    const res = await app.inject({
      method: "POST",
      url: "/v1/billing/google/verify",
      headers: authHeader(app),
      payload: { purchaseToken: TOKEN, productId: PRODUCT },
    });

    expect(res.statusCode).toBe(403);
    expect(res.json()).toEqual({ error: "owner_role_required" });
    expect(play.verifySubscription).not.toHaveBeenCalled();
    expect(store.grant).not.toHaveBeenCalled();
    await app.close();
  });

  it("refuses a stale token whose family claim is not the parent's current family", async () => {
    const store = recordingStore();
    setEntitlementStore(store as unknown as EntitlementStore);
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

describe("POST /v1/billing/google/rtdn", () => {
  it("takes the state from Play and the notification type as the cause", async () => {
    const store = recordingStore();
    const play = fakePlay();
    await bindPurchase(store);
    // Type 3 is "canceled", but the family has paid to the end of the period: Play says active.
    play.verifySubscription.mockResolvedValue(verified({ state: "active", autoRenews: false }));
    const app = await buildApp((a) => billingRoutes(a, deps({ play })), "/v1/billing");

    const res = await app.inject({ method: "POST", url: "/v1/billing/google/rtdn", ...pushPayload(subscriptionNotification(3), "msg-canceled") });

    expect(res.statusCode).toBe(204);
    expect(store.grant).toHaveBeenCalledTimes(1);
    expect(store.grant.mock.calls[0][0]).toMatchObject({
      familyId: "fam-1",
      state: "active",
      autoRenews: false,
      cause: "canceled",
      storeRef: TOKEN,
      effectiveAt: "2026-11-12T09:00:00.000Z",
    });
    expect(store.revoke).not.toHaveBeenCalled();
    await app.close();
  });

  it("stamps the server's clock when Play's event time is in the future", async () => {
    const store = recordingStore();
    const play = fakePlay();
    await bindPurchase(store);
    const before = Date.now();
    const app = await buildApp((a) => billingRoutes(a, deps({ play })), "/v1/billing");

    const res = await app.inject({
      method: "POST",
      url: "/v1/billing/google/rtdn",
      ...pushPayload(subscriptionNotification(2, TOKEN, "2030-01-01T00:00:00Z"), "msg-future-time"),
    });

    expect(res.statusCode).toBe(204);
    const stamped = Date.parse(store.grant.mock.calls[0][0].effectiveAt);
    expect(stamped).toBeGreaterThanOrEqual(before - 1000);
    expect(stamped).toBeLessThanOrEqual(Date.now() + 1000);
    await app.close();
  });

  it("goes active without renewal, then expired, over a cancelled-then-expired sequence", async () => {    const store = recordingStore();
    const play = fakePlay();
    await bindPurchase(store);
    play.verifySubscription
      .mockResolvedValueOnce(verified({ state: "active", autoRenews: false }))
      .mockResolvedValueOnce(verified({ state: "expired", autoRenews: false }));
    const app = await buildApp((a) => billingRoutes(a, deps({ play })), "/v1/billing");

    const cancelled = await app.inject({ method: "POST", url: "/v1/billing/google/rtdn", ...pushPayload(subscriptionNotification(3), "msg-1-cancelled") });
    const expired = await app.inject({ method: "POST", url: "/v1/billing/google/rtdn", ...pushPayload(subscriptionNotification(13), "msg-2-expired") });

    expect(cancelled.statusCode).toBe(204);
    expect(expired.statusCode).toBe(204);
    expect(store.grant.mock.calls[0][0]).toMatchObject({ state: "active", autoRenews: false, cause: "canceled" });
    expect(store.revoke.mock.calls[0][0]).toMatchObject({ state: "expired", autoRenews: false, cause: "expired" });
    expect(store.grant).toHaveBeenCalledTimes(1);
    expect(store.revoke).toHaveBeenCalledTimes(1);
    await app.close();
  });

  it("leaves the state unchanged when a push is replayed", async () => {
    const store = recordingStore();
    const play = fakePlay();
    await bindPurchase(store);
    play.verifySubscription.mockResolvedValue(verified({ state: "expired", autoRenews: false }));
    const app = await buildApp((a) => billingRoutes(a, deps({ play })), "/v1/billing");
    const payload = pushPayload(subscriptionNotification(2), "msg-replayed");

    const first = await app.inject({ method: "POST", url: "/v1/billing/google/rtdn", ...payload });
    const second = await app.inject({ method: "POST", url: "/v1/billing/google/rtdn", ...payload });

    expect(first.statusCode).toBe(204);
    expect(second.statusCode).toBe(204);
    // Dedupe is claimed before the re-verify, so the second delivery neither calls Play nor the store.
    expect(play.verifySubscription).toHaveBeenCalledTimes(1);
    expect(store.revoke).toHaveBeenCalledTimes(1);
    expect(store.grant).not.toHaveBeenCalled();
    await app.close();
  });

  it("answers 503 when Play cannot be reached, and applies the retry", async () => {
    const store = recordingStore();
    const log = vi.fn();
    const play = fakePlay();
    await bindPurchase(store);
    play.verifySubscription
      .mockRejectedValueOnce(new PlayUnavailable("verify_status_503"))
      .mockResolvedValueOnce(verified({ state: "active", autoRenews: true }));
    const app = await buildApp((a) => billingRoutes(a, deps({ play, log })), "/v1/billing");
    const payload = pushPayload(subscriptionNotification(2), "msg-play-down");

    const failed = await app.inject({ method: "POST", url: "/v1/billing/google/rtdn", ...payload });
    const retried = await app.inject({ method: "POST", url: "/v1/billing/google/rtdn", ...payload });

    expect(failed.statusCode).not.toBe(204);
    expect(failed.statusCode).toBeGreaterThanOrEqual(500);
    expect(retried.statusCode).toBe(204);
    expect(store.grant).toHaveBeenCalledTimes(1);
    await app.close();
  });

  it("acknowledges and logs a notification whose type it does not recognise", async () => {
    const store = recordingStore();
    const log = vi.fn();
    const play = fakePlay();
    await bindPurchase(store);
    const app = await buildApp((a) => billingRoutes(a, deps({ play, log })), "/v1/billing");

    const res = await app.inject({ method: "POST", url: "/v1/billing/google/rtdn", ...pushPayload(subscriptionNotification(99), "msg-unknown") });

    expect(res.statusCode).toBe(204);
    // Play's state is authoritative even when the label is not: the change still lands.
    expect(store.grant.mock.calls[0][0]).toMatchObject({ state: "active", cause: "unknown_notification_type:99" });
    expect(log).toHaveBeenCalledWith("billing.rtdn.unknown_type", expect.objectContaining({ messageId: "msg-unknown", type: 99 }));
    await app.close();
  });

  it("answers 204 for a purchase it never stored, without calling Play", async () => {
    const store = recordingStore();
    setEntitlementStore(store as unknown as EntitlementStore);
    const log = vi.fn();
    const play = fakePlay();
    await bindPurchase(store);
    const app = await buildApp((a) => billingRoutes(a, deps({ play, log })), "/v1/billing");

    const res = await app.inject({ method: "POST", url: "/v1/billing/google/rtdn", ...pushPayload(subscriptionNotification(2, "tok-never-verified"), "msg-stranger") });

    expect(res.statusCode).toBe(204);
    expect(play.verifySubscription).not.toHaveBeenCalled();
    expect(store.grant).not.toHaveBeenCalled();
    expect(log).toHaveBeenCalledWith("billing.rtdn.unknown_purchase", expect.objectContaining({ messageId: "msg-stranger" }));
    await app.close();
  });

  it("refuses an unverified push token and touches nothing", async () => {
    const store = recordingStore();
    await bindPurchase(store);
    const play = fakePlay();
    const app = await buildApp((a) => billingRoutes(a, deps({ play })), "/v1/billing");

    const res = await app.inject({ method: "POST", url: "/v1/billing/google/rtdn", ...pushPayload(subscriptionNotification(3), "msg-forged", "forged-token") });

    expect(res.statusCode).toBe(401);
    expect(res.json()).toEqual({ error: "invalid_push_token" });
    expect(play.verifySubscription).not.toHaveBeenCalled();
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
    setEntitlementStore(store as unknown as EntitlementStore);
    const log = vi.fn();
    const play = fakePlay();
    const app = await buildApp((a) => billingRoutes(a, deps({ play, log })), "/v1/billing");

    const res = await app.inject({
      method: "POST",
      url: "/v1/billing/google/rtdn",
      ...pushPayload({ packageName: "com.osratech.parent", testNotification: { version: "1.0" } }, "msg-test"),
    });

    expect(res.statusCode).toBe(204);
    expect(play.verifySubscription).not.toHaveBeenCalled();
    expect(store.grant).not.toHaveBeenCalled();
    expect(log).toHaveBeenCalledWith("billing.rtdn.no_subscription", expect.objectContaining({ messageId: "msg-test" }));
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

  it("names every known notification type, and labels the unknown ones", () => {
    const known: Array<[number, string]> = [
      [1, "recovered"],
      [2, "renewed"],
      [3, "canceled"],
      [4, "purchased"],
      [5, "on_hold"],
      [6, "in_grace_period"],
      [7, "restarted"],
      [8, "price_change"],
      [10, "paused"],
      [12, "revoked"],
      [13, "expired"],
    ];
    for (const [type, cause] of known) expect(notificationCause(type), `type ${type}`).toEqual({ cause, known: true });
    expect(notificationCause(999)).toEqual({ cause: "unknown_notification_type:999", known: false });
    expect(notificationCause(undefined)).toEqual({ cause: "unknown_notification_type", known: false });
  });
});

describe("log hygiene", () => {
  it("never writes the account id or the store reference to a log line", async () => {
    const store = recordingStore();
    setEntitlementStore(store as unknown as EntitlementStore);
    const log = vi.fn();
    const play = fakePlay();
    const app = await buildApp((a) => billingRoutes(a, deps({ play, log })), "/v1/billing");

    const verifiedRes = await app.inject({
      method: "POST",
      url: "/v1/billing/google/verify",
      headers: authHeader(app),
      payload: { purchaseToken: TOKEN, productId: PRODUCT },
    });
    // The refusal path logs a reason too, and must not log the id that did not match.
    const refused = await app.inject({
      method: "POST",
      url: "/v1/billing/google/verify",
      headers: authHeader(app),
      payload: { purchaseToken: TOKEN, productId: "com.osratech.family.yearly" },
    });
    const pushed = await app.inject({ method: "POST", url: "/v1/billing/google/rtdn", ...pushPayload(subscriptionNotification(2), "msg-log-hygiene") });

    expect(verifiedRes.statusCode).toBe(200);
    expect(refused.statusCode).toBe(400);
    expect(pushed.statusCode).toBe(204);
    expect(log).toHaveBeenCalled();
    const written = JSON.stringify(log.mock.calls);
    expect(written).not.toContain(ACCOUNT_ID);
    expect(written).not.toContain(TOKEN);
    await app.close();
  });
});
