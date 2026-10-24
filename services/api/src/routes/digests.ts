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

/**
 * Mail the "confirm this address" links issued by a save. Returns the addresses whose mail failed so the
 * answer can say `unsent`: a row whose link was never delivered is not a link the family is waiting on, so
 * it is cleared here (freeing its place under `MAX_PENDING_CONFIRMATIONS`) and the next save mails it
 * again. The save itself stands either way.
 */
async function mailConfirmations(
  familyId: string,
  confirmations: Array<{ email: string; token: string }>,
  log: { error: (obj: unknown, msg?: string) => void },
): Promise<Set<string>> {
  const failed = new Set<string>();
  for (const { email, token } of confirmations) {
    const link = `${appPublicUrl()}/v1/digests/confirm?token=${encodeURIComponent(token)}`;
    const result = await getEmailSender()
      .send(digestConfirmEmail(email, { link }))
      .catch((err: unknown) => ({ ok: false as const, reason: (err as Error)?.message ?? "send failed" }));
    if (result.ok) continue;
    failed.add(email);
    log.error({ reason: result.reason }, "digest confirmation email failed");
    // No mail left the building, so the link is not live: clear it, and the address stops counting
    // against the cap. Without this a family whose provider was down would sit out the 24 hours with
    // links nobody ever saw.
    await prisma.digestRecipient
      .update({
        where: { familyId_email: { familyId, email } },
        data: { tokenHash: null, tokenExpiresAt: null },
      })
      .catch((err: unknown) => log.error({ err }, "could not clear an unsent digest link"));
  }
  return failed;
}

/**
 * The page a browser sees after pressing the button (review of #354): the confirmed and the expired cases,
 * in English and Arabic, in the same shape as the page that carries the button. A form POST gets this; a
 * JSON caller keeps JSON. It says nothing about an address, so it is safe to render for any token.
 */
function resultPage(confirmed: boolean): string {
  const en = confirmed
    ? "Confirmed. This address will now receive the family's OSRA digest."
    : "This link has expired or was already used.";
  const ar = confirmed
    ? "تمّ التأكيد. سيصل ملخّص العائلة من أسرة إلى هذا العنوان."
    : "انتهت صلاحية هذا الرابط أو سبق استخدامه.";
  return `<!doctype html>
<html>
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>OSRA</title></head>
<body style="margin:0;background:#f6f7fb;font-family:-apple-system,Segoe UI,Roboto,Arial,sans-serif;color:#1f2430">
  <div style="max-width:520px;margin:0 auto;padding:24px">
    <div dir="ltr" style="background:#fff;border-radius:8px;padding:24px">
      <p style="margin:0;line-height:1.5">${en}</p>
    </div>
    <div dir="rtl" style="background:#fff;border-radius:8px;padding:24px;margin-top:16px">
      <p style="margin:0;line-height:1.5">${ar}</p>
    </div>
  </div>
</body>
</html>`;
}

export async function digestRoutes(app: FastifyInstance) {
  // The confirmation page's <form> posts as application/x-www-form-urlencoded, which Fastify has no parser
  // for: without this it answers 415 before the handler runs, so no address could ever be confirmed. The
  // token rides in the form's action URL, so the body is read and dropped. Registered inside this plugin,
  // so only /v1/digests accepts the type.
  app.addContentTypeParser(
    "application/x-www-form-urlencoded",
    { parseAs: "string", bodyLimit: 1024 },
    (_req, _body, done) => done(null, {}),
  );

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
   * The answer marks every address `confirmed`, `pending` or `unsent`; a pending one either already has a
   * live link or was mailed one by this save, and it receives nothing until that link is used. `limited`
   * says the family's live-link budget was spent, so this save mailed nothing for it.
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
    const failed = await mailConfirmations(user.familyId, confirmations, req.log);
    const recipients = statuses.map((status) =>
      failed.has(status.email) ? { email: status.email, status: "unsent" as const } : status,
    );
    return reply.code(200).send({ ...prefs, recipients });
  });

  /**
   * The confirmation page, and only that. GET **spends nothing** (review of #354, item 3): a mail scanner
   * or a link preview that follows the URL must not confirm an address a person never agreed to. The page
   * carries one button, and the button POSTs the token back to `POST /confirm`, which is what spends it.
   *
   * The page states nothing about the token, so following the link tells a scanner nothing about whether
   * it exists.
   */
  app.get("/confirm", async (req, reply) => {
    const parsed = ConfirmSchema.safeParse(req.query);
    if (!parsed.success) return reply.code(400).send({ error: "invalid_token" });
    const action = `/v1/digests/confirm?token=${encodeURIComponent(parsed.data.token)}`;
    // `ConfirmSchema` admits only 64 hex characters, so the action needs no HTML escaping.
    const button =
      'style="background:#3949ab;color:#fff;border:0;padding:12px 18px;border-radius:8px;font-size:16px"';
    const html = `<!doctype html>
<html>
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>OSRA</title></head>
<body style="margin:0;background:#f6f7fb;font-family:-apple-system,Segoe UI,Roboto,Arial,sans-serif;color:#1f2430">
  <div style="max-width:520px;margin:0 auto;padding:24px">
    <div dir="ltr" style="background:#fff;border-radius:8px;padding:24px">
      <h2 style="margin:0 0 12px;font-size:20px">Confirm an OSRA family digest</h2>
      <p style="margin:0 0 16px;line-height:1.5">Press the button to confirm this address. Nothing is sent to it until you do.</p>
      <form method="post" action="${action}"><button type="submit" ${button}>Confirm this address</button></form>
    </div>
    <div dir="rtl" style="background:#fff;border-radius:8px;padding:24px;margin-top:16px">
      <h2 style="margin:0 0 12px;font-size:20px">تأكيد ملخّص عائلة في أسرة</h2>
      <p style="margin:0 0 16px;line-height:1.5">اضغط الزر لتأكيد هذا العنوان. لن يُرسَل إليه شيء قبل ذلك.</p>
      <form method="post" action="${action}"><button type="submit" ${button}>تأكيد هذا العنوان</button></form>
    </div>
  </div>
</body>
</html>`;
    return reply.type("text/html; charset=utf-8").header("cache-control", "no-store").send(html);
  });

  /**
   * Spend the link: the button on the page above posts its token here. No session — the token is the
   * credential. It is single-use, it expires 24 hours after the save that issued it, and unknown, expired
   * and already-used links answer the same 404, so a caller cannot tell which addresses are on a list.
   *
   * A browser posts from the page above, so the answer is a page rather than raw JSON: the form's content
   * type is the only thing that distinguishes the two callers, and JSON callers keep JSON.
   */
  app.post("/confirm", async (req, reply) => {
    // The token rides in the query string (the page's form action), so no form-body parser is needed;
    // a JSON caller may send it in the body instead.
    const body = (req.body ?? {}) as { token?: string };
    const query = (req.query ?? {}) as { token?: string };
    const fromForm = (req.headers["content-type"] ?? "").startsWith("application/x-www-form-urlencoded");
    const parsed = ConfirmSchema.safeParse({ token: body.token ?? query.token });
    if (!parsed.success) {
      return fromForm
        ? reply.type("text/html; charset=utf-8").header("cache-control", "no-store").code(400).send(resultPage(false))
        : reply.code(400).send({ error: "invalid_token" });
    }
    const confirmed = await confirmRecipient(parsed.data.token);
    if (!confirmed) {
      return fromForm
        ? reply.type("text/html; charset=utf-8").header("cache-control", "no-store").code(404).send(resultPage(false))
        : reply.code(404).send({ error: "confirmation_not_found_or_expired" });
    }
    if (fromForm) {
      return reply.type("text/html; charset=utf-8").header("cache-control", "no-store").send(resultPage(true));
    }
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
