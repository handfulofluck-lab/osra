import type { FastifyInstance } from "fastify";
import { z } from "zod";
import { prisma } from "../db.js";
import { requireParent } from "../middleware/requireFamily.js";
import { ReauthSchema, checkReauth, consentHeldElsewhere, eraseParentAccount } from "../lib/accountDeletion.js";
import { AUTH_RATE_LIMIT } from "../lib/rateLimits.js";

/**
 * Parent-self routes (Phase 2a): push-token registry for the signed-in parent, and (#442) deleting
 * one's own account.
 * A token belongs to one parent; re-registering an existing token (new install, token refresh
 * on the same device, or a second parent logging in on that phone) moves it to the caller.
 */

const PushTokenSchema = z.object({
  token: z.string().min(20).max(4096),
  platform: z.enum(["android", "ios", "web"]),
  appVersion: z.string().max(40).optional(),
});

type AuthedUser = { sub: string; familyId: string };

export async function meRoutes(app: FastifyInstance) {
  app.post("/push-token", { preHandler: requireParent }, async (req, reply) => {
    const parsed = PushTokenSchema.safeParse(req.body);
    if (!parsed.success) return reply.code(400).send({ error: parsed.error.flatten() });
    const user = req.user as AuthedUser;
    const { token, platform, appVersion } = parsed.data;
    const row = await prisma.parentPushToken.upsert({
      where: { token },
      update: { parentId: user.sub, platform, appVersion, lastSeenAt: new Date() },
      create: { parentId: user.sub, token, platform, appVersion },
    });
    return reply.code(201).send({ id: row.id, platform: row.platform, registeredAt: row.createdAt });
  });

  /** Called on logout so a shared phone stops receiving the previous parent's alerts. */
  app.delete("/push-token", { preHandler: requireParent }, async (req, reply) => {
    const parsed = z.object({ token: z.string().min(1) }).safeParse(req.body);
    if (!parsed.success) return reply.code(400).send({ error: parsed.error.flatten() });
    const user = req.user as AuthedUser;
    const result = await prisma.parentPushToken.deleteMany({ where: { token: parsed.data.token, parentId: user.sub } });
    return { removed: result.count };
  });

  app.get("/push-tokens", { preHandler: requireParent }, async (req) => {
    const user = req.user as AuthedUser;
    const tokens = await prisma.parentPushToken.findMany({
      where: { parentId: user.sub },
      select: { id: true, platform: true, appVersion: true, createdAt: true, lastSeenAt: true },
      orderBy: { lastSeenAt: "desc" },
    });
    return { tokens };
  });

  /**
   * #442 (Play account deletion): a co-parent or guardian deletes their own account — their `Parent`
   * row and the rows that are theirs alone. The family and the children stay. The owner deletes the
   * whole family instead (`DELETE /v1/family`), so here they get `409 owner_must_delete_family`:
   * ownership transfer is a later feature, and a family with no owner could not be managed or deleted.
   *
   * Same re-authentication as the family deletion: `{ password, mfaCode? }`, `401 reauth_failed`, and
   * the same `409 consent_records_held` (`consentHeldElsewhere`).
   */
  app.delete("/", { preHandler: requireParent, config: { rateLimit: AUTH_RATE_LIMIT } }, async (req, reply) => {
    const parsed = ReauthSchema.safeParse(req.body);
    if (!parsed.success) return reply.code(400).send({ error: parsed.error.flatten() });
    const user = req.user as AuthedUser;
    const parent = await prisma.parent.findUnique({ where: { id: user.sub } });
    if (!parent) return reply.code(404).send({ error: "parent_not_found" });
    if (parent.role === "owner") return reply.code(409).send({ error: "owner_must_delete_family" });
    const refusal = await checkReauth(parent, parsed.data);
    if (refusal) return reply.code(401).send({ error: refusal });
    if ((await consentHeldElsewhere([parent.id], parent.familyId)) > 0) {
      return reply.code(409).send({ error: "consent_records_held" });
    }
    return reply.code(200).send(await eraseParentAccount(parent));
  });
}
