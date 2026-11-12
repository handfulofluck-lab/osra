import type { FastifyInstance, FastifyReply, FastifyRequest } from "fastify";
import { z } from "zod";
import { prisma } from "../db.js";
import { requireParent } from "../middleware/requireFamily.js";
import {
  findFamilyForPurchase,
  grantEntitlement,
  isRevoking,
  revokeEntitlement,
  type EntitlementChange,
} from "../lib/entitlement.js";
import {
  PlayUnavailable,
  PurchaseAlreadyOwned,
  PurchaseRejected,
  assertPurchaseBelongsToFamily,
  createPlayClient,
  createServiceAccountTokenProvider,
  obfuscatedAccountIdFor,
  type PlayClient,
  type VerifiedPurchase,
} from "../lib/billing/google.js";
import {
  MalformedNotification,
  createGoogleOidcVerifier,
  createRedisSeenMessages,
  decodeNotification,
  mapNotificationType,
  type OidcVerifier,
  type SeenMessages,
} from "../lib/billing/rtdn.js";

/**
 * Play Billing verification and real-time developer notifications (ADR-0041 D2, issue #620).
 *
 * `POST /google/verify` is the parent app's half: it proves a purchase token is real, that it belongs
 * to the caller's family, acknowledges it so Play does not refund it, and reports the state through
 * the entitlement seam. `POST /google/rtdn` is Google's half: a Pub/Sub push, authenticated by the
 * OIDC token rather than by a parent session, that keeps the plan current with no app involved.
 *
 * Neither route reads or writes a billing table. Everything the plan means goes through
 * `lib/entitlement.ts`, which is B1's (#619) to replace behind the same calls.
 */

/** What a route needs from outside; every field is optional so `app.register(billingRoutes)` works. */
export interface BillingDeps {
  /**
   * The Play client, or `null` for "not configured". Injected by tests; by default built from
   * `PLAY_PACKAGE_NAME` and the service-account secret named by `PLAY_SERVICE_ACCOUNT_SECRET_NAME`.
   */
  play?: PlayClient | null;
  /** Fetch a secret's contents by name. The route supplies it (see `PLAY_SERVICE_ACCOUNT_SECRET_NAME`). */
  loadSecret?: (name: string) => Promise<string>;
  /** Pub/Sub OIDC verifier. Injected by tests; by default built from the two `PLAY_RTDN_*` names. */
  verifyPushToken?: OidcVerifier;
  /** RTDN dedupe set. Injected by tests; by default Redis (`SET NX`). */
  seen?: SeenMessages;
  /** Structured log sink. Injected by tests so "ignored, and logged" is assertable. */
  log?: (event: string, fields?: Record<string, unknown>) => void;
}

type Log = (event: string, fields?: Record<string, unknown>) => void;

const VerifySchema = z.object({
  purchaseToken: z.string().trim().min(1).max(4096),
  productId: z.string().trim().min(1).max(200),
});

/** The Pub/Sub push envelope. Extra members are ignored: Google adds fields over time. */
const RtdnEnvelopeSchema = z
  .object({
    message: z
      .object({
        data: z.string().min(1),
        messageId: z.string().min(1).max(200),
      })
      .passthrough(),
    subscription: z.string().optional(),
  })
  .passthrough();

const redisSeen = createRedisSeenMessages();

/** Built once per process so the verifier's certificate cache survives a burst of pushes. */
let envVerifier: OidcVerifier | null = null;
let envPlay: Promise<PlayClient | null> | null = null;

function loggerFor(opts: BillingDeps, req: FastifyRequest): Log {
  return opts.log ?? ((event, fields) => req.log.warn(fields ?? {}, event));
}

function bearerToken(header: string | undefined): string | null {
  if (!header) return null;
  const [scheme, ...rest] = header.trim().split(/\s+/);
  if (scheme?.toLowerCase() !== "bearer") return null;
  const token = rest.join("");
  return token.length > 0 ? token : null;
}

function pushVerifier(opts: BillingDeps): OidcVerifier | null {
  if (opts.verifyPushToken) return opts.verifyPushToken;
  const audience = process.env.PLAY_RTDN_AUDIENCE?.trim();
  const serviceAccountEmail = process.env.PLAY_RTDN_SERVICE_ACCOUNT_EMAIL?.trim();
  if (!audience || !serviceAccountEmail) return null;
  envVerifier ??= createGoogleOidcVerifier({ audience, serviceAccountEmail });
  return envVerifier;
}

/**
 * The Play client from the environment, or `null` when this deployment has no Play credentials.
 *
 * The service-account JSON is fetched **by name** through [BillingDeps.loadSecret]; without a loader
 * this route cannot talk to Play at all, which is a 503 rather than a guess. No key, path or project
 * id appears here or in the tests.
 */
async function buildEnvPlay(opts: BillingDeps, log: Log): Promise<PlayClient | null> {
  const packageName = process.env.PLAY_PACKAGE_NAME?.trim();
  const secretName = process.env.PLAY_SERVICE_ACCOUNT_SECRET_NAME?.trim();
  if (!packageName || !secretName) {
    log("billing.play.not_configured", { missing: [!packageName && "PLAY_PACKAGE_NAME", !secretName && "PLAY_SERVICE_ACCOUNT_SECRET_NAME"].filter(Boolean) });
    return null;
  }
  if (!opts.loadSecret) {
    log("billing.play.no_secret_loader", { secretName });
    return null;
  }
  const serviceAccountJson = await opts.loadSecret(secretName);
  return createPlayClient({ packageName, getAccessToken: createServiceAccountTokenProvider(serviceAccountJson) });
}

async function resolvePlay(opts: BillingDeps, log: Log): Promise<PlayClient | null> {
  if (opts.play !== undefined) return opts.play;
  envPlay ??= buildEnvPlay(opts, log).catch((err: unknown) => {
    // A failed secret fetch is not cached: the next request tries again rather than staying dark.
    envPlay = null;
    throw err;
  });
  return envPlay;
}

/** The seam's write: `revoked`/`expired` are revocations, `active`/`grace`/`on_hold` are grants. */
async function applyChange(change: EntitlementChange): Promise<void> {
  if (isRevoking(change.state)) await revokeEntitlement(change);
  else await grantEntitlement(change);
}

/** One status per typed refusal: 400 forged, 403 another family's, 503 Play's own trouble. */
function refusal(reply: FastifyReply, log: Log, err: unknown) {
  if (err instanceof PurchaseRejected) {
    log("billing.verify.rejected", { reason: err.reason });
    return reply.code(400).send({ error: err.code });
  }
  if (err instanceof PurchaseAlreadyOwned) {
    log("billing.verify.foreign_purchase", { reason: err.reason });
    return reply.code(403).send({ error: err.code });
  }
  if (err instanceof PlayUnavailable) {
    log("billing.verify.play_unavailable", { reason: err.reason });
    return reply.code(503).send({ error: err.code });
  }
  throw err as Error;
}

/** The notification's own timestamp, so a delayed push records when Play acted, not when we heard. */
function eventTime(notification: { eventTimeMillis?: string }): string {
  const millis = Number(notification.eventTimeMillis);
  const at = Number.isFinite(millis) && millis > 0 ? new Date(millis) : new Date();
  return at.toISOString();
}

export async function billingRoutes(app: FastifyInstance, opts: BillingDeps = {}): Promise<void> {
  app.post("/google/verify", { preHandler: requireParent }, async (req, reply) => {
    const log = loggerFor(opts, req);
    const parsed = VerifySchema.safeParse(req.body);
    if (!parsed.success) return reply.code(400).send({ error: parsed.error.flatten() });

    const user = req.user as { sub?: string; familyId?: string };
    const parent = user.sub
      ? await prisma.parent.findUnique({ where: { id: user.sub }, select: { familyId: true } })
      : null;
    if (!parent) return reply.code(401).send({ error: "unauthorized" });
    // The token's `familyId` is a snapshot from minting time; the Parent row is authoritative, the same
    // rule `requireFamily` applies. A stale claim must not decide which family a plan is written to.
    if (user.familyId && user.familyId !== parent.familyId) return reply.code(403).send({ error: "forbidden" });

    let play: PlayClient | null;
    try {
      play = await resolvePlay(opts, log);
    } catch (err) {
      log("billing.play.unavailable", { error: (err as Error).message });
      return reply.code(503).send({ error: "play_unavailable" });
    }
    if (!play) return reply.code(503).send({ error: "play_unavailable" });

    let purchase: VerifiedPurchase;
    try {
      purchase = await play.verifySubscription(parsed.data.purchaseToken);
      assertPurchaseBelongsToFamily(obfuscatedAccountIdFor(parent.familyId), purchase);
    } catch (err) {
      return refusal(reply, log, err);
    }

    // The body's productId is what the client believes it bought; a mismatch means the request and the
    // purchase describe different things, which is a refusal rather than something to reconcile.
    if (purchase.productId !== parsed.data.productId) {
      log("billing.verify.product_mismatch", { productId: purchase.productId });
      return reply.code(400).send({ error: "purchase_rejected" });
    }

    if (purchase.acknowledgementState === "pending") {
      try {
        await play.acknowledgeSubscription(parsed.data.purchaseToken, purchase.productId);
      } catch (err) {
        // Play refunds an unacknowledged purchase after three days, so this is worth a log line — but
        // refusing here would take away a plan the family has already paid for over a retryable fault.
        log("billing.verify.acknowledge_failed", { productId: purchase.productId, error: (err as Error).message });
      }
    }

    const change: EntitlementChange = {
      familyId: parent.familyId,
      source: "google",
      state: purchase.state,
      externalId: purchase.externalId,
      effectiveAt: new Date().toISOString(),
      cause: "verify",
    };
    try {
      await applyChange(change);
    } catch (err) {
      log("billing.verify.entitlement_failed", { familyId: parent.familyId, error: (err as Error).message });
      return reply.code(503).send({ error: "entitlement_unavailable" });
    }

    return reply.code(200).send({
      state: change.state,
      source: change.source,
      productId: purchase.productId,
      expiryTime: purchase.expiryTime,
    });
  });

  /**
   * The Pub/Sub push. No parent session: the OIDC token **is** the authentication, and it is verified
   * before the body is looked at. 204 on success and on every notification we deliberately do not act
   * on — Pub/Sub retries anything that is not a 2xx, so an unknown type or a purchase we never saw must
   * be acknowledged and logged rather than answered with an error that loops forever.
   */
  app.post("/google/rtdn", async (req, reply) => {
    const log = loggerFor(opts, req);

    const verifier = pushVerifier(opts);
    if (!verifier) {
      log("billing.rtdn.not_configured", {});
      return reply.code(503).send({ error: "rtdn_not_configured" });
    }
    const token = bearerToken(req.headers.authorization);
    if (!token) return reply.code(401).send({ error: "invalid_push_token" });
    try {
      await verifier(token);
    } catch (err) {
      log("billing.rtdn.bad_push_token", { reason: (err as Error).message });
      return reply.code(401).send({ error: "invalid_push_token" });
    }

    const parsed = RtdnEnvelopeSchema.safeParse(req.body);
    if (!parsed.success) return reply.code(400).send({ error: "malformed_notification" });
    const { data, messageId } = parsed.data.message;

    let notification: ReturnType<typeof decodeNotification>;
    try {
      notification = decodeNotification(data);
    } catch (err) {
      if (!(err instanceof MalformedNotification)) throw err;
      log("billing.rtdn.malformed", { messageId, reason: err.reason });
      return reply.code(400).send({ error: "malformed_notification" });
    }

    const seen = opts.seen ?? redisSeen;
    if (!(await seen.claim(messageId))) {
      log("billing.rtdn.duplicate", { messageId });
      return reply.code(204).send();
    }

    try {
      const sub = notification.subscriptionNotification;
      if (!sub?.purchaseToken) {
        log("billing.rtdn.no_subscription", { messageId, packageName: notification.packageName ?? null });
        return reply.code(204).send();
      }

      const mapping = mapNotificationType(sub.notificationType);
      if (mapping.kind === "ignored") {
        log("billing.rtdn.ignored", { messageId, type: sub.notificationType ?? null, reason: mapping.reason });
        return reply.code(204).send();
      }

      const familyId = await findFamilyForPurchase("google", sub.purchaseToken);
      if (!familyId) {
        // A purchase we never verified: nothing to attribute it to, and inventing a family would be
        // worse than the miss. It is logged so a real gap shows up as a metric, not as silence.
        log("billing.rtdn.unknown_purchase", { messageId, type: mapping.typeName });
        return reply.code(204).send();
      }

      await applyChange({
        familyId,
        source: "google",
        state: mapping.state,
        externalId: sub.purchaseToken,
        effectiveAt: eventTime(notification),
        cause: mapping.cause,
      });
      return reply.code(204).send();
    } catch (err) {
      // The claim is handed back so the store's retry of this same message can still land.
      await seen.release(messageId).catch(() => undefined);
      log("billing.rtdn.failed", { messageId, error: (err as Error).message });
      return reply.code(503).send({ error: "rtdn_retry" });
    }
  });
}
