import type { FastifyInstance, FastifyReply, FastifyRequest } from "fastify";
import { z } from "zod";
import { prisma } from "../db.js";
import { appPublicUrl, emailConfigured, getEmailSender } from "../lib/email/index.js";
import { inviteEmail } from "../lib/email/templates.js";
import { getJson, setJson } from "../redis.js";
import { requireAuth, requireOwner, requireParent } from "../middleware/requireFamily.js";
import { invalidateSessionsBefore, signParentToken } from "../lib/sessions.js";

const INVITE_TTL_SECONDS = 7 * 24 * 60 * 60; // 7 days
/**
 * Roadmap 2.7 (osra-security#2): twenty invites a family a day. This follows the counting idiom the
 * MFA-reset limit already uses (`auth.ts`, `mfaResetRequest.count` over a 24-hour window): the invites are
 * rows, the rows are the record, and a count cannot drift from what was created. A keyed cache would need
 * its own lifetime and would still have to be reconciled with these rows after a flush.
 */
const INVITES_PER_DAY = 20;
const INVITE_WINDOW_MS = 24 * 60 * 60 * 1000;

const InviteCreateSchema = z.object({
  email: z.string().email(),
  role: z.enum(["co-parent", "guardian"]),
  permissions: z.array(z.string()).default([]),
});

type AuthedUser = { sub: string; familyId: string };
type InviteToken = { familyId: string; email: string; role: string; permissions: string[] };

/** Redis key holding the accept token payload for an invite. */
function inviteKey(id: string): string {
  return `invite:${id}`;
}

/** Strip credential material from a parent row before it leaves the API. */
const sanitizeParent = ({ passwordHash: _ph, mfaSecret: _ms, ...rest }: Record<string, unknown>) => rest;

export async function inviteRoutes(app: FastifyInstance) {
  /** Create a family invite (owner only); the accept token lives in Redis for 7 days. */
  // NOTE: the test build returns the accept token inline — production emails a
  // register/login link carrying the token instead of exposing it in the response.
  app.post("/invites", { preHandler: [requireParent, requireOwner] }, async (req, reply) => {
    const parsed = InviteCreateSchema.safeParse(req.body);
    if (!parsed.success) return reply.code(400).send({ error: parsed.error.flatten() });
    const user = req.user as AuthedUser;
    const { email, role, permissions } = parsed.data;
    const normalizedEmail = email.toLowerCase();

    const recent = (await prisma.familyInvite.count({
      where: { familyId: user.familyId, createdAt: { gt: new Date(Date.now() - INVITE_WINDOW_MS) } },
    })) ?? 0;
    if (recent >= INVITES_PER_DAY) return reply.code(429).send({ error: "invite_limit_reached" });

    const invite = await prisma.familyInvite.create({
      data: { familyId: user.familyId, email: normalizedEmail, role, permissions, status: "pending" },
    });
    const token: InviteToken = { familyId: user.familyId, email: normalizedEmail, role, permissions };
    await setJson(inviteKey(invite.id), token, INVITE_TTL_SECONDS);
    // Phase 2a: the invitee gets a link by email. The accept token is echoed in the response only
    // while no email provider is configured (dev/test builds), never in production.
    const [inviter, family] = await Promise.all([
      prisma.parent.findUnique({ where: { id: user.sub } }),
      prisma.family.findUnique({ where: { id: user.familyId } }),
    ]);
    const link = `${appPublicUrl()}/invite/accept?token=${encodeURIComponent(invite.id)}`;
    const sent = await getEmailSender().send(
      inviteEmail(normalizedEmail, { inviterName: inviter?.displayName ?? "A parent", familyName: family?.name ?? "your", role, link }),
    );
    if (!sent.ok) req.log.error({ reason: sent.reason }, "invite email failed");
    const echoToken = !emailConfigured() && process.env.NODE_ENV !== "production";
    return reply.code(201).send({ invite, emailed: sent.ok && emailConfigured(), ...(echoToken ? { acceptToken: invite.id } : {}) });
  });

  /** List the family's invites (any parent of the family). */
  app.get("/invites", { preHandler: requireParent }, async (req) => {
    const user = req.user as AuthedUser;
    const invites = await prisma.familyInvite.findMany({
      where: { familyId: user.familyId },
      orderBy: { createdAt: "desc" },
    });
    return { invites, items: invites };
  });

  /** Accept an invite: attach the authenticated parent to the inviting family. */
  app.post("/invites/:id/accept", { preHandler: requireAuth }, async (req, reply) => {
    const { id } = req.params as { id: string };
    const token = await getJson<InviteToken>(inviteKey(id));
    if (!token) return reply.code(404).send({ error: "invite_not_found_or_expired" });

    const invite = await prisma.familyInvite.findUnique({ where: { id } });
    if (!invite) return reply.code(404).send({ error: "invite_not_found_or_expired" });
    if (invite.status !== "pending") return reply.code(409).send({ error: "invite_not_pending" });

    const user = req.user as AuthedUser;
    const parent = await prisma.parent.findUnique({ where: { id: user.sub } });
    if (!parent) return reply.code(401).send({ error: "unauthorized" });
    if (parent.email.toLowerCase() !== token.email.toLowerCase()) {
      return reply.code(403).send({ error: "email_mismatch" });
    }

    const updated = await prisma.parent.update({
      where: { id: parent.id },
      data: { familyId: token.familyId, role: token.role, permissions: token.permissions },
    });
    // The move happens here: every access token minted while this parent belonged to the previous
    // family (which still carries the old `familyId` claim) must die now, exactly like logout-all /
    // password reset. The fresh token below is minted after the counter bump, so it carries the new
    // sessions version (#117).
    // Since #158 a failed counter bump throws (the accept returns 5xx and the client retries); it is
    // no longer best-effort. `requireFamily` also compares against the current Parent row, so the
    // old family claim cannot read its data even before the counter is repaired.
    await invalidateSessionsBefore(parent.id);
    await prisma.familyInvite.update({ where: { id }, data: { status: "accepted" } });
    const family = await prisma.family.findUnique({ where: { id: token.familyId } });
    // Issue a fresh access token bound to the new family ID (BUG-006 / API-05)
    // ADR-0014: the JWT `role` is always "parent" (it selects the parent surface — `requireParent`
    // used to reject the "co-parent"/"guardian" tokens minted here, locking invitees out until they
    // logged in again); the family role travels as `familyRole`.
    const { token: freshToken } = await signParentToken(app, { id: parent.id, familyId: token.familyId, role: token.role }, { expiresIn: "15m" });
    return {
      family,
      parent: sanitizeParent(updated as unknown as Record<string, unknown>),
      token: freshToken,
      accessToken: freshToken,
    };
  });

  /** Revoke a pending invite (owner only). */
  app.delete("/invites/:id", { preHandler: [requireParent, requireOwner] }, async (req, reply) => {
    const user = req.user as AuthedUser;
    const { id } = req.params as { id: string };
    const invite = await prisma.familyInvite.findUnique({ where: { id } });
    if (!invite) return reply.code(404).send({ error: "invite_not_found" });
    if (invite.familyId !== user.familyId) return reply.code(403).send({ error: "forbidden" });
    const revoked = await prisma.familyInvite.update({ where: { id }, data: { status: "revoked" } });
    return { invite: revoked };
  });
}
