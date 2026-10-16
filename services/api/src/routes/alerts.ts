import type { FastifyInstance } from "fastify";
import type { Prisma } from "@prisma/client";
import { z } from "zod";
import { prisma } from "../db.js";
import { publishFamilyEvent } from "../realtime/gateway.js";
import { registerRawBodyParser, authenticateInternalRequest } from "../lib/internalAuth.js";
import { assertProcessingAllowed } from "../lib/consent.js";
import { requireFamily, requireParent } from "../middleware/requireFamily.js";

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
});

/** Minimal push-enqueue interface; real providers deliver via FCM (Android) / APNs (iOS). */
export interface PushProvider {
  sendToFamily(familyId: string, payload: { title: string; body: string; data: unknown }): Promise<void>;
}

// NOTE: production would inject a real FcmApnsPush wired to Firebase/APNs credentials; this
// stub only logs so the alert pipeline is complete end-to-end without push infra.
export class FcmApnsPush implements PushProvider {
  async sendToFamily(familyId: string, payload: { title: string; body: string; data: unknown }): Promise<void> {
    console.log(`[push:stub] family=${familyId} title=${payload.title}`);
  }
}

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
  app.post("/:id/ack", { preHandler: [requireParent, requireFamily({ model: "alert" })] }, async (req) => {
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
      return reply.code(401).send({ error: "invalid_signature" });
    }
    const parsed = InternalAlertSchema.safeParse(req.body);
    if (!parsed.success) return reply.code(400).send({ error: parsed.error.flatten() });
    const { childId, deviceId, severity, category, title, body, metadata } = parsed.data;

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

    const alert = await prisma.alert.create({
      data: { childId, deviceId: effectiveDeviceId, severity, category, title, body, metadata: (metadata ?? {}) as Prisma.InputJsonValue },
    });

    const event = { type: "alert", payload: alert, ts: new Date().toISOString() };
    await publishFamilyEvent(child.familyId, event);

    const push: PushProvider = new FcmApnsPush();
    await push.sendToFamily(child.familyId, { title, body, data: alert });
    return reply.code(201).send({ alert });
  });

}
