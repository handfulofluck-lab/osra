import type { FastifyInstance } from "fastify";
import { z } from "zod";
import { prisma } from "../db.js";
import { registerRawBodyParser, authenticateInternalRequest } from "../lib/internalAuth.js";
import { raiseAlertOnce } from "../lib/alerts.js";
import { assertProcessingAllowed } from "../lib/consent.js";
import { requireFamily, requireParent, requirePermission } from "../middleware/requireFamily.js";

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
  app.get("/", { preHandler: requireParent }, async (req, reply) => {
    const user = req.user as AuthedUser;
    const parsed = ListQuerySchema.safeParse(req.query ?? {});
    if (!parsed.success) return reply.code(400).send({ error: parsed.error.flatten() });
    const query = parsed.data;
    const where = {
      child: { familyId: user.familyId },
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
    return { items: alerts, meta: { total, page: query.page, limit: query.limit } };
  });

  /** Acknowledge an alert. */
  app.post("/:id/ack", { preHandler: [requireParent, requirePermission("alerts"), requireFamily({ model: "alert" })] }, async (req) => {
    const { id } = req.params as { id: string };
    const alert = await prisma.alert.update({ where: { id }, data: { acknowledged: true } });
    return { alert };
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
    const { childId, deviceId, severity, category, title, body, metadata, dedupeKey, attemptCount } = parsed.data;

    if (auth.device) {
      // P0-5: Verify device is not revoked
      if (auth.device.revokedAt) {
        return reply.code(401).send({ error: "device_revoked" });
      }
      // P0-4: Prevent cross-child injection: signing device must belong to this child
      if (auth.device.childId && auth.device.childId !== childId) {
        return reply.code(400).send({ error: "cross_child_alert_forbidden" });
      }
      // If a deviceId was explicitly passed in body, it must match the signing device
      if (deviceId && deviceId !== auth.device.id) {
        return reply.code(400).send({ error: "device_mismatch" });
      }
    }

    const child = await prisma.child.findUnique({ where: { id: childId } });
    if (!child) return reply.code(404).send({ error: "child_not_found" });
    // ADR-0008 §2b: withdrawal of consent stops collection.
    if (!(await assertProcessingAllowed(childId, reply))) return;

    const effectiveDeviceId = deviceId ?? auth.device?.id;

    // Phase 2a: one path creates the row, publishes the WS event and pushes to the parents' phones.
    // Issue #225: a repeated dedupeKey is a retry, not a new alert — 200 with the existing row.
    const { alert, deduplicated } = await raiseAlertOnce({
      childId,
      familyId: child.familyId,
      deviceId: effectiveDeviceId,
      severity,
      category,
      title,
      body,
      metadata,
      dedupeKey,
      attemptCount,
      childName: child.displayName,
    });
    return reply.code(deduplicated ? 200 : 201).send({ alert });
  });

}
