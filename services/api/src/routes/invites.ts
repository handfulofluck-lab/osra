import { createHash, randomBytes } from "node:crypto";
import type { FastifyInstance, FastifyReply, FastifyRequest } from "fastify";
import { z } from "zod";
import { prisma } from "../db.js";
import { appPublicUrl, emailConfigured, getEmailSender } from "../lib/email/index.js";
import { inviteEmail } from "../lib/email/templates.js";
import { getJson, getRedis, setJson } from "../redis.js";
import { requireAuth, requireOwner, requireParent } from "../middleware/requireFamily.js";
import { invalidateSessionsBefore, signParentToken } from "../lib/sessions.js";

const INVITE_TTL_SECONDS = 7 * 24 * 60 * 60; // 7 days
/**
 * Roadmap 2.7 (osra-security#2): twenty invites a family a day. This follows the counting idiom the
 * MFA-reset limit already uses (`auth.ts`, `mfaResetRequest.count` over a 24-hour window): the invites are
 * rows, the rows are the record, and a count cannot drift from what was created. A keyed cache would need
 * its own lifetime and would still have to be reconciled with these rows after a flush.
 *
 * The count and the create are two statements, so a burst of parallel requests can pass 20 by the size of
 * the burst. That is fine for a daily abuse limit whose subject is a family, not a single mailbox: the
 * overshoot is bounded by the concurrency in flight, it costs the same as the twentieth, and the rows it
 * creates are the record either way.
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

/**
 * The mailed link's secret (#804, Ahmed's B1). The inviter sees `invite.id` (the create response, the
 * list, the revoke URL), so the id cannot be what opens the web accept page: that page takes a password,
 * and it must be reachable only by whoever reads the invited mailbox. The link carries 256 random bits
 * instead; Redis holds only their SHA-256, pointing at the invite, for the invite's own lifetime. The
 * secret is in the mail and nowhere else: not in a response, not in a log, not in the database.
 */
export const INVITE_SECRET_PATTERN = /^[0-9a-f]{64}$/;
const hashInviteSecret = (secret: string) => createHash("sha256").update(secret).digest("hex");
const inviteSecretKey = (secret: string) => `invite:accept:${hashInviteSecret(secret)}`;

/** The invite id a mailed secret stands for, or null. Reads only. */
export async function inviteIdForSecret(secret: string): Promise<string | null> {
  if (!INVITE_SECRET_PATTERN.test(secret)) return null;
  return getRedis().get(inviteSecretKey(secret));
}

/** Strip credential material from a parent row before it leaves the API. */
const sanitizeParent = ({ passwordHash: _ph, mfaSecret: _ms, ...rest }: Record<string, unknown>) => rest;

type AcceptRefusal = { ok: false; status: 401 | 403 | 404 | 409; error: string };
type AcceptDone = { ok: true; familyId: string; role: string; parent: { id: string } & Record<string, unknown> };

/**
 * A pending invite that can still be accepted, or null. Reads only: the page a mailed link opens
 * (`routes/linkPages.ts`, #789) uses it to decide what to show, and a mail scanner following the link
 * changes nothing.
 */
export async function findOpenInvite(id: string): Promise<{ email: string } | null> {
  const token = await getJson<InviteToken>(inviteKey(id));
  if (!token) return null;
  const invite = await prisma.familyInvite.findUnique({ where: { id } });
  return invite && invite.status === "pending" ? { email: token.email } : null;
}

/**
 * Move `parent` into the inviting family. The one implementation behind `POST /v1/family/invites/:id/accept`
 * (the caller proved who they are with a session) and the page the mailed link opens (#789: the caller
 * proved it with the account's password). Whoever calls has already established that `parent` is the
 * person acting; this checks that the invite is live and addressed to them.
 */
export async function acceptInvite(
  id: string,
  parent: { id: string; email: string } | null,
  missingParentError = "unauthorized",
): Promise<AcceptRefusal | AcceptDone> {
  const token = await getJson<InviteToken>(inviteKey(id));
  if (!token) return { ok: false, status: 404, error: "invite_not_found_or_expired" };

  const invite = await prisma.familyInvite.findUnique({ where: { id } });
  if (!invite) return { ok: false, status: 404, error: "invite_not_found_or_expired" };
  if (invite.status !== "pending") return { ok: false, status: 409, error: "invite_not_pending" };

  if (!parent) return { ok: false, status: 401, error: missingParentError };
  if (parent.email.toLowerCase() !== token.email.toLowerCase()) {
    return { ok: false, status: 403, error: "email_mismatch" };
  }

  const updated = await prisma.parent.update({
    where: { id: parent.id },
    data: { familyId: token.familyId, role: token.role, permissions: token.permissions },
  });
  // The move happens here: every access token minted while this parent belonged to the previous
  // family (which still carries the old `familyId` claim) must die now, exactly like logout-all /
  // password reset. A token the caller mints afterwards carries the new sessions version (#117).
  // Since #158 a failed counter bump throws (the accept returns 5xx and the client retries); it is
  // no longer best-effort. `requireFamily` also compares against the current Parent row, so the
  // old family claim cannot read its data even before the counter is repaired.
  await invalidateSessionsBefore(parent.id);
  await prisma.familyInvite.update({ where: { id }, data: { status: "accepted" } });
  return { ok: true, familyId: token.familyId, role: token.role, parent: updated as unknown as AcceptDone["parent"] };
}

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
    // The mailed link's secret, written first: without the invite record below it opens nothing.
    const secret = randomBytes(32).toString("hex");
    await getRedis().set(inviteSecretKey(secret), invite.id, "EX", INVITE_TTL_SECONDS);
    const token: InviteToken = { familyId: user.familyId, email: normalizedEmail, role, permissions };
    await setJson(inviteKey(invite.id), token, INVITE_TTL_SECONDS);
    // Phase 2a: the invitee gets a link by email. The accept token is echoed in the response only
    // while no email provider is configured (dev/test builds), never in production.
    const [inviter, family] = await Promise.all([
      prisma.parent.findUnique({ where: { id: user.sub } }),
      prisma.family.findUnique({ where: { id: user.familyId } }),
    ]);
    const link = `${appPublicUrl()}/invite/accept?token=${secret}`;
    const sent = await getEmailSender().send(
      inviteEmail(normalizedEmail, { inviterName: inviter?.displayName ?? null, familyName: family?.name ?? null, role, link }),
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
    const user = req.user as AuthedUser;
    const parent = await prisma.parent.findUnique({ where: { id: user.sub } });
    // An unknown invite answers 404 before the caller's own row is judged, as it always has.
    const result = await acceptInvite(id, parent, "unauthorized");
    if (!result.ok) return reply.code(result.status).send({ error: result.error });
    const family = await prisma.family.findUnique({
      where: { id: result.familyId },
      select: { id: true, name: true, region: true, timezone: true, timezoneSource: true, createdAt: true },
    });
    // Issue a fresh access token bound to the new family ID (BUG-006 / API-05)
    // ADR-0014: the JWT `role` is always "parent" (it selects the parent surface — `requireParent`
    // used to reject the "co-parent"/"guardian" tokens minted here, locking invitees out until they
    // logged in again); the family role travels as `familyRole`.
    const { token: freshToken } = await signParentToken(app, { id: result.parent.id, familyId: result.familyId, role: result.role }, { expiresIn: "15m" });
    return {
      family,
      parent: sanitizeParent(result.parent as unknown as Record<string, unknown>),
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
