import type { FastifyInstance } from "fastify";
import { z } from "zod";
import { prisma } from "../db.js";
import { requireFamily, requireParent, sanitizeDevice } from "../middleware/requireFamily.js";
import { requireConsent } from "../middleware/requireConsent.js";
import { checkActiveConsent } from "../lib/consent.js";
import { enqueueDeviceCommand } from "../lib/deviceCommands.js";
import { publishFamilyEvent } from "../realtime/gateway.js";
import { defaultRuleSetRow } from "../lib/defaultRules.js";
import { getRedis } from "../redis.js";
import { eraseChildData, screenTimeTodayFromDb } from "../lib/usageModel.js";
import { DEVICE_TOKEN_TTL_SECONDS } from "../lib/deviceToken.js";

const ConsentCreateSchema = z.object({
  method: z.enum(["sms_plus", "kba", "face_match", "credit_card"]),
  jurisdiction: z.string().min(1),
  thirdPartySharing: z.boolean().optional(),
  expiresAt: z.string().datetime().optional(),
});

const ChildCreateSchema = z.object({
  displayName: z.string().min(1),
  birthYear: z.number().int().min(1900).max(new Date().getFullYear()),
  avatarUrl: z.string().url().optional(),
  // Inline VPC payload: when present the child is created together with its
  // ConsentRecord in one transaction (the app's consent-first add-child flow).
  consent: ConsentCreateSchema.optional(),
});

const ChildPatchSchema = z.object({
  displayName: z.string().min(1).optional(),
  birthYear: z.number().int().min(1900).max(new Date().getFullYear()).optional(),
  avatarUrl: z.string().url().nullable().optional(),
});

type AuthedUser = { sub: string; familyId: string };

/** Strip credential material from a parent row before it leaves the API. */
const sanitizeParent = ({ passwordHash: _ph, mfaSecret: _ms, ...rest }: Record<string, unknown>) => rest;

export async function familyRoutes(app: FastifyInstance) {
  /** Return the authenticated parent's family envelope: family, parents, children (with devices) and a flat device list. */
  app.get("/me", { preHandler: requireParent }, async (req, reply) => {
    const user = req.user as AuthedUser;
    const family = await prisma.family.findUnique({
      where: { id: user.familyId },
      include: {
        parents: true,
        children: { include: { devices: true, ruleSet: true, consents: true, geofences: true } },
      },
    });
    if (!family) return reply.code(404).send({ error: "family_not_found" });
    const parents = family.parents.map(sanitizeParent);
    const parent = parents.find((p) => p.id === user.sub) ?? parents[0];
    // Strip internal secrets and push tokens from parent-facing payloads, and include screenTimeTodayMinutes (FLT-02)
    const redis = getRedis();
    const children = await Promise.all(
      family.children.map(async (c) => {
        let screenTimeTodayMinutes = 0;
        const today = new Date().toISOString().slice(0, 10);
        const childUsageKey = `usage:child:${c.id}:${today}`;
        const accumulated = await redis.get(childUsageKey).catch(() => null);
        // Phase 2c: the Redis key is a cache of the durable AppUsageDaily rows; a flush or restart
        // must not read as "0 minutes today".
        const durable = accumulated === null ? await screenTimeTodayFromDb(c.id).catch(() => 0) : 0;
        if (accumulated !== null) {
          screenTimeTodayMinutes = parseInt(accumulated, 10) || 0;
        } else if (durable > 0) {
          screenTimeTodayMinutes = durable;
        } else {
          for (const d of c.devices) {
            const raw = await redis.get(`device:${d.id}:telemetry`).catch(() => null);
            if (raw) {
              try {
                const tel = JSON.parse(raw);
                if (typeof tel.totalMinutes === "number") {
                  screenTimeTodayMinutes += tel.totalMinutes;
                }
              } catch {}
            }
          }
        }
        return {
          ...c,
          screenTimeTodayMinutes,
          devices: c.devices.map(sanitizeDevice),
        };
      }),
    );
    const devices = children.flatMap((c) => c.devices);
    const { parents: _parents, ...familyRest } = family;
    return { family: { ...familyRest, children }, parent, parents, children, devices };
  });

  /** Create a child; gated on an active jurisdiction-matching ConsentRecord (428 otherwise). */
  app.post("/children", { preHandler: requireParent }, async (req, reply) => {
    const parsed = ChildCreateSchema.safeParse(req.body);
    if (!parsed.success) return reply.code(400).send({ error: parsed.error.flatten() });
    const user = req.user as AuthedUser;

    const family = await prisma.family.findUnique({ where: { id: user.familyId } });
    if (!family) return reply.code(404).send({ error: "family_not_found" });

    const { consent: inlineConsent, ...childData } = parsed.data;

    // Inline VPC path: consent collected in the same request creates the child
    // and its ConsentRecord atomically. The consent jurisdiction must match the
    // family's region (the COPPA/GDPR-K gate from spec §12.5).
    if (inlineConsent) {
      if (inlineConsent.jurisdiction !== family.region) {
        return reply.code(428).send({ error: "consent_jurisdiction_mismatch", jurisdiction: family.region });
      }
      const created = await prisma.$transaction(async (tx) => {
        const child = await tx.child.create({ data: { familyId: family.id, ...childData } });
        const consent = await tx.consentRecord.create({
          data: {
            childId: child.id,
            parentId: user.sub,
            method: inlineConsent.method,
            jurisdiction: inlineConsent.jurisdiction,
            thirdPartySharing: inlineConsent.thirdPartySharing ?? false,
            expiresAt: inlineConsent.expiresAt ? new Date(inlineConsent.expiresAt) : null,
          },
        });
        // Feature #1: every new child starts with the full default-protection ruleset.
        await tx.ruleSet.upsert({
          where: { childId: child.id },
          create: defaultRuleSetRow(child.id),
          update: {},
        });
        return { child, consent };
      });
      return reply.code(201).send(created);
    }

    // Strict gate (spec §12.5): without inline consent there is no ConsentRecord
    // that can belong to this not-yet-existing child, so creation is refused.
    // Consent for already-registered children is managed via
    // POST /children/:id/consent (renewal / revocation).
    return reply.code(428).send({ error: "parental_consent_required", jurisdiction: family.region });
  });

  /** Return a single child of the authenticated family. */
  app.get("/children/:id", { preHandler: [requireParent, requireFamily({ model: "child" })] }, async (req) => {
    const child = (req as unknown as { child: unknown }).child;
    return child;
  });

  /** Update a child's profile fields. */
  app.patch("/children/:id", { preHandler: [requireParent, requireFamily({ model: "child" }), requireConsent({ param: "id" })] }, async (req, reply) => {
    const parsed = ChildPatchSchema.safeParse(req.body);
    if (!parsed.success) return reply.code(400).send({ error: parsed.error.flatten() });
    const { id } = req.params as { id: string };
    const child = await prisma.child.update({ where: { id }, data: parsed.data });
    return child;
  });

  /**
   * GDPR erasure cascade: delete the child and every child-scoped record (ADR-0013). The list of
   * tables and Redis keys lives in `eraseChildData()` so there is one place to extend; each deleted
   * device's token is revoked like an unpair (#56). The response reports the row counts so a caller
   * (and the e2e gate) can see what was removed.
   */
  app.delete("/children/:id", { preHandler: [requireParent, requireFamily({ model: "child" })] }, async (req) => {
    const { id } = req.params as { id: string };
    return eraseChildData(id, DEVICE_TOKEN_TTL_SECONDS);
  });

  /** Record a parental-consent event (VPC) for an existing child. */
  app.post("/children/:id/consent", { preHandler: [requireParent, requireFamily({ model: "child" })] }, async (req, reply) => {
    const parsed = ConsentCreateSchema.safeParse(req.body);
    if (!parsed.success) return reply.code(400).send({ error: parsed.error.flatten() });
    const user = req.user as AuthedUser;
    const { id } = req.params as { id: string };
    // The §12.5 jurisdiction rule applies here too: a ConsentRecord whose jurisdiction
    // differs from the family region can never satisfy the consent gate.
    const family = await prisma.family.findUnique({ where: { id: user.familyId } });
    if (!family) return reply.code(404).send({ error: "family_not_found" });
    if (parsed.data.jurisdiction !== family.region) {
      return reply.code(428).send({ error: "consent_jurisdiction_mismatch", jurisdiction: family.region });
    }
    const consent = await prisma.consentRecord.create({
      data: {
        childId: id,
        parentId: user.sub,
        method: parsed.data.method,
        jurisdiction: parsed.data.jurisdiction,
        thirdPartySharing: parsed.data.thirdPartySharing ?? false,
        expiresAt: parsed.data.expiresAt ? new Date(parsed.data.expiresAt) : null,
      },
    });
    // ADR-0008 §3: re-granting restores processing; tell paused agents to resume.
    const devices = await prisma.device.findMany({ where: { childId: id }, select: { id: true } });
    for (const { id: deviceId } of devices ?? []) {
      await enqueueDeviceCommand(deviceId, "consent_granted", { childId: id }).catch(() => undefined);
    }
    return reply.code(201).send({ consent });
  });

  /** Current consent status for a child (ADR-0008). */
  app.get("/children/:id/consent", { preHandler: [requireParent, requireFamily({ model: "child" })] }, async (req) => {
    const { id } = req.params as { id: string };
    const user = req.user as AuthedUser;
    const family = await prisma.family.findUnique({ where: { id: user.familyId } });
    return checkActiveConsent(id, family?.region);
  });

  /**
   * Revoke parental consent for an existing child (ADR-0008 §1).
   *
   * Revocation stops processing, not only configuration: every device of the child is told to
   * pause monitoring (`consent_revoked` command) and, from this moment, device ingestion and
   * device reads answer 428 until a parent re-grants consent. Device pairings are kept so that
   * re-granting resumes without re-enrolment.
   */
  app.post("/children/:id/consent/revoke", { preHandler: [requireParent, requireFamily({ model: "child" })] }, async (req, reply) => {
    const { id } = req.params as { id: string };
    const user = req.user as AuthedUser;
    const now = new Date();
    const updated = await prisma.consentRecord.updateMany({
      where: { childId: id, revokedAt: null },
      data: { revokedAt: now },
    });
    const devices = await prisma.device.findMany({ where: { childId: id }, select: { id: true } });
    for (const { id: deviceId } of devices) {
      // Best-effort signal; the 428 on the agent's next poll is the authoritative stop.
      await enqueueDeviceCommand(deviceId, "consent_revoked", { childId: id, revokedAt: now.toISOString() }).catch(() => undefined);
    }
    await publishFamilyEvent(user.familyId, {
      type: "consent_revoked",
      payload: { childId: id, revokedBy: user.sub, revokedAt: now.toISOString(), devicesNotified: devices.length },
      ts: now.toISOString(),
    }).catch(() => undefined);
    return reply.code(200).send({
      revoked: true,
      childId: id,
      count: updated.count,
      devicesNotified: devices.length,
      revokedAt: now.toISOString(),
    });
  });

  /** GDPR data export: JSON download of family, children, devices and consents. */
  // NOTE: simplest acceptable export per spec — a JSON attachment. Production should
  // deliver an encrypted archive and notify the parent out-of-band.
  app.get("/export", { preHandler: requireParent }, async (req, reply) => {
    const user = req.user as AuthedUser;
    const family = await prisma.family.findUnique({
      where: { id: user.familyId },
      include: {
        parents: true,
        children: {
          include: { devices: true, ruleSet: true, consents: true, geofences: true, alerts: true },
        },
      },
    });
    if (!family) return reply.code(404).send({ error: "family_not_found" });
    reply.header("Content-Disposition", `attachment; filename="familyshield-export-${family.id}.json"`);
    // Strip internal secrets and push tokens from the export too.
    const exportChildren = family.children.map((c) => ({
      ...c,
      devices: c.devices.map(sanitizeDevice),
    }));
    return {
      exportedAt: new Date().toISOString(),
      family: { ...family, parents: family.parents.map(sanitizeParent), children: exportChildren },
    };
  });
}
