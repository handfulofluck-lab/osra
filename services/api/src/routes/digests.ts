import type { FastifyInstance } from "fastify";
import { z } from "zod";
import { prisma } from "../db.js";
import { requireOwner, requireParent } from "../middleware/requireFamily.js";
import { summarizeChildActivity, type ActivitySummary } from "../lib/activitySummary.js";
import { sendFamilyDigest } from "../jobs/digestScheduler.js";
import { appPublicUrl, emailConfigured, getEmailSender } from "../lib/email/index.js";
import { digestConfirmEmail } from "../lib/email/templates.js";
import {
  MAX_DIGEST_RECIPIENTS,
  confirmRecipient,
  parentEmailsOf,
  recipientStatuses,
  stageRecipients,
} from "../lib/digestRecipients.js";
import { setJsonNx } from "../redis.js";

const PrefsSchema = z.object({
  dailyEmail: z.boolean(),
  weeklyEmail: z.boolean(),
  pushEnabled: z.boolean(),
  // Roadmap 2.7 (osra-security#2): the list is bounded, and normalized so that one mailbox cannot take
  // two slots under two spellings of the same address.
  emails: z
    .array(z.string().email().transform((email) => email.trim().toLowerCase()))
    .min(1)
    .max(MAX_DIGEST_RECIPIENTS),
});

const ConfirmSchema = z.object({ token: z.string().regex(/^[a-f0-9]{64}$/) });

/** The `send-now` throttle window (roadmap 2.7): one a family per hour, on top of the daily key. */
export const SEND_NOW_WINDOW_SECONDS = 60 * 60;

type AuthedUser = { sub: string; familyId: string };

/** Default prefs when no DigestPrefs row exists: everything on, delivered to the parent's email. */
async function prefsOrDefault(familyId: string, parentId: string) {
  const row = await prisma.digestPrefs.findUnique({ where: { familyId } });
  if (row) return row;
  const parent = await prisma.parent.findUnique({ where: { id: parentId } });
  return {
    familyId,
    dailyEmail: true,
    weeklyEmail: true,
    pushEnabled: true,
    emails: parent ? [parent.email] : [],
  };
}

/**
 * Claim the family's hourly `send-now` slot. `SET NX EX` is the repo's one-shot key idiom
 * (`pair:{code}` in routes/devices.ts): one command, atomic, and the TTL is the window itself.
 *
 * A Redis outage allows the send and says so: this is a throttle, and turning an unreachable cache into
 * "the family gets no digest at all" is the worse failure. The provider's once-a-day idempotency key is
 * still in force underneath, so the exposure is one extra request per outage.
 */
async function claimSendNow(familyId: string, warn: (message: string) => void): Promise<boolean> {
  try {
    return await setJsonNx(
      `digest:send-now:${familyId}`,
      { at: new Date().toISOString() },
      SEND_NOW_WINDOW_SECONDS,
    );
  } catch (err) {
    warn(`[digest] send-now throttle unavailable, allowing this send: ${(err as Error)?.message ?? err}`);
    return true;
  }
}

/** Render one child's summary as a markdown-ish digest body (#5). */
function renderDigest(displayName: string, days: number, summary: ActivitySummary): string {
  const lines = [
    `## OSRA digest — ${displayName}`,
    `Screen time (last ${days} days): ${summary.totalAppMinutes} min`,
    `Top apps: ${summary.topApps.map((a) => `${a.name} ${a.minutes}m`).join(", ") || "none"}`,
    `URL visits: ${summary.urlVisits}`,
    `Blocked domains: ${summary.topBlockedDomains.map((d) => `${d.domain} (${d.count})`).join(", ") || "none"}`,
    `Social concerns: ${summary.socialConcerns}`,
    `Calls: ${summary.calls}, SMS: ${summary.sms}`,
  ];
  return lines.join("\n");
}

/** Mail the "confirm this address" links issued by a save. Best-effort: the save itself stands. */
async function mailConfirmations(
  familyId: string,
  confirmations: Array<{ email: string; token: string }>,
  log: { error: (obj: unknown, msg?: string) => void },
): Promise<void> {
  if (confirmations.length === 0) return;
  const family = await prisma.family.findUnique({ where: { id: familyId } });
  const familyName = family?.name ?? "your";
  for (const { email, token } of confirmations) {
    const link = `${appPublicUrl()}/v1/digests/confirm?token=${encodeURIComponent(token)}`;
    const result = await getEmailSender()
      .send(digestConfirmEmail(email, { familyName, link }))
      .catch((err: unknown) => ({ ok: false as const, reason: (err as Error)?.message ?? "send failed" }));
    if (!result.ok) log.error({ reason: result.reason }, "digest confirmation email failed");
  }
}

export async function digestRoutes(app: FastifyInstance) {
  /** Read the family's digest preferences (default: all-true, emails=[parent email]) (#5). */
  app.get("/prefs", { preHandler: requireParent }, async (req) => {
    const user = req.user as AuthedUser;
    const prefs = await prefsOrDefault(user.familyId, user.sub);
    // Readable by any parent of the family; the statuses are what lets the screen say "confirmation
    // sent" for an address that has not proved itself yet.
    const parents = await parentEmailsOf(user.familyId);
    const recipients = await recipientStatuses(user.familyId, prefs.emails, parents);
    return { ...prefs, recipients };
  });

  /**
   * Upsert the family's digest preferences (#5). Owner only (roadmap 2.7): the list is where mail leaves
   * the family, so changing it is the same class of act as inviting a member or editing the family.
   *
   * The answer marks every address `confirmed` or `pending`; a pending one gets a single-use 24-hour
   * link and receives nothing until it is used.
   */
  app.put("/prefs", { preHandler: [requireParent, requireOwner] }, async (req, reply) => {
    const parsed = PrefsSchema.safeParse(req.body);
    if (!parsed.success) return reply.code(400).send({ error: parsed.error.flatten() });
    const user = req.user as AuthedUser;
    const parents = await parentEmailsOf(user.familyId);
    const { statuses, confirmations } = await stageRecipients(user.familyId, parsed.data.emails, parents);
    const prefs = await prisma.digestPrefs.upsert({
      where: { familyId: user.familyId },
      update: parsed.data,
      create: { familyId: user.familyId, ...parsed.data },
    });
    await mailConfirmations(user.familyId, confirmations, req.log);
    return reply.code(200).send({ ...prefs, recipients: statuses });
  });

  /**
   * Spend a confirmation link from a digest-confirmation email. No session: the token is the credential,
   * it is single-use, and it expires 24 hours after the save that issued it.
   */
  app.get("/confirm", async (req, reply) => {
    const parsed = ConfirmSchema.safeParse(req.query);
    if (!parsed.success) return reply.code(400).send({ error: "invalid_token" });
    const confirmed = await confirmRecipient(parsed.data.token);
    if (!confirmed) return reply.code(404).send({ error: "confirmation_not_found_or_expired" });
    return { confirmed: true, email: confirmed.email };
  });

  /**
   * Render the digest for every child and, when an email provider is configured, deliver it to the
   * family's **confirmed** digest recipients right now (Phase 2a). Scheduled delivery is
   * `jobs/digestScheduler.ts`; this route is the parent-triggered "send me one now".
   *
   * Owner only and one send per family per hour (roadmap 2.7): a "test" button that mails an arbitrary
   * list is a relay, so it is throttled and its recipients are the same confirmed set the scheduler uses.
   */
  app.post("/send-now", { preHandler: [requireParent, requireOwner] }, async (req, reply) => {
    const user = req.user as AuthedUser;
    if (!(await claimSendNow(user.familyId, (message) => req.log.warn(message)))) {
      return reply.code(429).send({ error: "digest_send_limit_reached" });
    }
    const body = (req.body ?? {}) as { kind?: "daily" | "weekly" };
    const kind = body.kind === "daily" ? "daily" : "weekly";
    const days = kind === "daily" ? 1 : 7;
    const children = await prisma.child.findMany({ where: { familyId: user.familyId } });
    const digests = [];
    for (const child of children) {
      const summary = await summarizeChildActivity(child.id, days);
      digests.push({
        childId: child.id,
        displayName: child.displayName,
        markdown: renderDigest(child.displayName, days, summary),
      });
    }
    const delivery = await sendFamilyDigest(user.familyId, kind);
    return { digests, emailed: delivery.sent && emailConfigured(), recipients: delivery.to, reason: delivery.reason };
  });
}
