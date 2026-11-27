import type { FastifyInstance } from "fastify";
import { z } from "zod";
import { prisma } from "../db.js";
import { registerRawBodyParser, authenticateInternalRequest } from "../lib/internalAuth.js";
import { redactedBlockedSiteKey, redactBlockedSiteHost, siteNamesEnabled } from "../lib/siteNames.js";
import { raiseAlertOnce, type RaiseAlertInput } from "../lib/alerts.js";
import { recordBlockedAttempt } from "../lib/blockedAttemptWindow.js";
import { incompleteDedupeKey, shouldHoldTamperDuringSetup, type SetupDevice } from "../lib/deviceSetup.js";
import { raisePhoneSetupNotice } from "../lib/deviceSetupTransitions.js";
import { sanitizeAlertMetadata, withoutAlertLocation } from "../lib/alertLocation.js";
import { assertProcessingAllowed } from "../lib/consent.js";
import { guardianPermissions, requireFamily, requireGuardianRead, requireParent, requirePermission } from "../middleware/requireFamily.js";

const ListQuerySchema = z.object({
  page: z.coerce.number().int().min(1).default(1),
  limit: z.coerce.number().int().min(1).max(100).default(20),
  childId: z.string().optional(),
  severity: z.enum(["info", "warning", "critical"]).optional(),
  category: z.string().optional(),
  ack: z.enum(["true", "false"]).optional(),
});

const InternalAlertSchema = z.object({
  childId: z.string().min(1),
  deviceId: z.string().optional(),
  severity: z.enum(["info", "warning", "critical"]),
  category: z.enum([
    "web_threat",
    "app_blocked",
    "screen_time_exceeded",
    "geofence",
    "sos",
    "ai_concern",
    "cyberbullying",
    "self_harm",
    "grooming",
    "tamper",
    "vpn_detected",
    "install_request",
    "unknown_contact",
  ]),
  title: z.string().min(1),
  body: z.string().min(1),
  metadata: z.record(z.unknown()).optional(),
  /**
   * Issue #225: producer idempotency key. `<deviceId>|<type>|<event timestamp>` makes a retry of a
   * device-admin-removed alert return the existing row instead of paging the parent twice.
   */
  dedupeKey: z.string().min(1).max(200).optional(),
  /**
   * Issue #227: attempts aggregated into one window alert. A repeat key with a higher count
   * updates the existing row instead of inserting or dropping the information.
   */
  attemptCount: z.number().int().min(1).max(10_000).optional(),
});

type AuthedUser = { familyId: string };

export async function alertsRoutes(app: FastifyInstance) {
  registerRawBodyParser(app);

  /** Paginated, filterable list of alerts scoped to the authenticated family's children. */
  app.get("/", { preHandler: [requireParent, requireGuardianRead("alerts")] }, async (req, reply) => {
    const user = req.user as AuthedUser;
    const parsed = ListQuerySchema.safeParse(req.query ?? {});
    if (!parsed.success) return reply.code(400).send({ error: parsed.error.flatten() });
    const query = parsed.data;
    const where = {
      child: { familyId: user.familyId },
      heldDuringSetup: false,
      ...(query.childId ? { childId: query.childId } : {}),
      ...(query.severity ? { severity: query.severity } : {}),
      ...(query.category ? { category: query.category } : {}),
      ...(query.ack !== undefined ? { acknowledged: query.ack === "true" } : {}),
    };
    const total = await prisma.alert.count({ where });
    const alerts = await prisma.alert.findMany({
      where,
      orderBy: { createdAt: "desc" },
      skip: (query.page - 1) * query.limit,
      take: query.limit,
    });
    // Issue #672 review (Fable B1, ADR-0014 amendment decision 3): a guardian may be given `alerts`
    // without `location`. The alert is theirs to read; the child's coordinates are not, so the five keys
    // come off every row on this broad read — the same rule that withholds geofences from `GET /v1/family`.
    // `guardianPermissions` is null for owners, co-parents and device tokens, so their rows are untouched.
    const perms = await guardianPermissions(req);
    const items = perms !== null && !perms.includes("location") ? alerts.map(withoutAlertLocation) : alerts;
    return { items, meta: { total, page: query.page, limit: query.limit } };
  });

  /** Acknowledge an alert. */
  app.post("/:id/ack", { preHandler: [requireParent, requirePermission("alerts"), requireFamily({ model: "alert" })] }, async (req, reply) => {
    if ((req as unknown as { alert?: { heldDuringSetup?: boolean } }).alert?.heldDuringSetup) {
      return reply.code(404).send({ error: "not_found" });
    }
    const { id } = req.params as { id: string };
    const alert = await prisma.alert.update({ where: { id }, data: { acknowledged: true } });
    // Issue #672 review (Claude's B1b): the ack returns the row, so a guardian holding `alerts` without
    // `location` would read the place here even though the list withholds it. Same rule, same helper.
    const perms = await guardianPermissions(req);
    return { alert: perms !== null && !perms.includes("location") ? withoutAlertLocation(alert) : alert };
  });

  /** HMAC-signed endpoint for device/AI-originated alerts (ai-engine, child agents). */
  app.post("/internal", async (req, reply) => {
    const rawBody = (req as { rawBody?: string }).rawBody;
    const auth = await authenticateInternalRequest(
      rawBody,
      req.headers["x-familyshield-signature"],
      req.headers as Record<string, string | string[] | undefined>,
    );
    if (!auth.valid) {
      return reply.code(401).send({ error: "invalid_signature", reason: auth.reason });
    }
    const parsed = InternalAlertSchema.safeParse(req.body);
    if (!parsed.success) return reply.code(400).send({ error: parsed.error.flatten() });
    const { childId, deviceId, severity, category, title, body, dedupeKey, attemptCount } = parsed.data;
    // Provider attribution and delivery identity are assigned by the server.
    const {
      providerOutcomes: _providerOutcomes,
      pushDeliveryId: _pushDeliveryId,
      pushDeliverySeq: _pushDeliverySeq,
      pushDeliveries: _pushDeliveries,
      summaryGroupedInto: _summaryGroupedInto,
      ...metadata
    } = parsed.data.metadata ?? {};

    if (auth.device) {
      // Revocation is not checked here: sessionGuard refuses device JWTs, and an unpaired phone has no
      // row to sign with (#351).
      // P0-4: Prevent cross-child injection: signing device must belong to this child
      if (auth.device.childId && auth.device.childId !== childId) {
        return reply.code(400).send({ error: "cross_child_alert_forbidden" });
      }
      // If a deviceId was explicitly passed in body, it must match the signing device
      if (deviceId && deviceId !== auth.device.id) {
        return reply.code(400).send({ error: "device_mismatch" });
      }
    }

    const child = await prisma.child.findUnique({ where: { id: childId }, include: { family: { select: { timezone: true } } } });
    if (!child) return reply.code(404).send({ error: "child_not_found" });
    // ADR-0008 §2b: withdrawal of consent stops collection.
    if (!(await assertProcessingAllowed(childId, reply))) return;

    const effectiveDeviceId = deviceId ?? auth.device?.id;
    // #1208: the phone's setup notice shares the server reminder's key (handled below, under the device lock).
    const setupNoticeDevice = auth.device && dedupeKey === incompleteDedupeKey(auth.device.id) ? auth.device : null;
    const heldDuringSetup = auth.device
      ? shouldHoldTamperDuringSetup(
          auth.device as unknown as SetupDevice,
          category,
          typeof metadata.type === "string" ? metadata.type : null,
          new Date(),
        )
      : false;

    // Claude's ruling on #841 finding 5: while the site-name flag is off, a blocked site is a count with no
    // host. The parent keeps the attempt; nothing in the row names a site, and the dedupe key groups by day.
    const redactSite = category === "web_threat" && !siteNamesEnabled();
    const safeMetadata = redactSite ? redactBlockedSiteHost(metadata) : metadata;
    // ADR-0047: held retries share a separate namespace so a real post-setup event with the
    // producer's original key creates a new visible row instead of deduplicating the held one.
    const safeDedupeKey = redactSite ? redactedBlockedSiteKey() : heldDuringSetup && dedupeKey ? `held|${dedupeKey}` : dedupeKey;

    // #1222 (Karim, 26 Nov): blocked sites and apps follow the #1139 grouped-alert rule. The first attempts
    // push, later ones are grouped and summarised every window, a quiet window starts a new row, and the day
    // follows the family's zone. The producer's per-UTC-day key only recognises a lost-response retry now.
    if ((category === "web_threat" || category === "app_blocked") && !heldDuringSetup) {
      const result = await recordBlockedAttempt({
        childId,
        familyId: child.familyId,
        childName: child.displayName,
        deviceId: effectiveDeviceId,
        timeZone: (child as { family?: { timezone?: string | null } | null }).family?.timezone ?? null,
        category,
        severity,
        title: redactSite ? "Blocked site opened" : title,
        body: redactSite ? "Your child tried to open a blocked site." : body,
        metadata: sanitizeAlertMetadata(safeMetadata) ?? {},
        siteNames: !redactSite,
        producerKey: dedupeKey ?? null,
        producerAttemptCount: attemptCount ?? null,
      });
      return reply.code(result.created ? 201 : 200).send({ alert: result.alert });
    }

    // Phase 2a: one path creates the row, publishes the WS event and pushes to the parents' phones.
    // Issue #225: a repeated dedupeKey is a retry, not a new alert — 200 with the existing row.
    const input: RaiseAlertInput = {
      childId,
      familyId: child.familyId,
      deviceId: effectiveDeviceId,
      severity,
      category,
      // A redacted web_threat carries no client text either: the title and body are free text that could
      // name a site, so the server owns both while the flag is off (Fable's blocker B).
      title: redactSite ? "Blocked site opened" : title,
      body: redactSite ? "Your child tried to open a blocked site." : body,
      // Issue #672: an SOS may carry where it was sent from, as the five flat keys the agent writes.
      // The location is normalised here — or dropped, keeping every other key — and never rejects the
      // alert: an SOS with no usable fix is still an SOS a parent must receive.
      metadata: sanitizeAlertMetadata(safeMetadata),
      dedupeKey: safeDedupeKey,
      attemptCount,
      heldDuringSetup,
      childName: child.displayName,
    };

    if (setupNoticeDevice) {
      // Decided under the Device row lock with the server-validated grants (Codex, #1230 finding 2 and
      // osra-security#82/#87): open setup dedupes onto the pairing's one notice; a completed pairing that the
      // server sees missing a newly required grant gets one new notice with the latch kept; a completed pairing
      // with every required grant is a stale retry and writes nothing. Publish and push run after commit.
      const pairedAt = (setupNoticeDevice as unknown as SetupDevice).pairedAt;
      const outcome = await raisePhoneSetupNotice(setupNoticeDevice.id, pairedAt, { ...input, attemptCount: undefined });
      if (!outcome) return reply.code(200).send({ dropped: "setup_complete" });
      return reply.code(outcome.deduplicated ? 200 : 201).send({ alert: outcome.alert });
    }
    const { alert, deduplicated } = await raiseAlertOnce(input);
    return reply.code(deduplicated ? 200 : 201).send({ alert });
  });

}
