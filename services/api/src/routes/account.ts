import type { FastifyBaseLogger, FastifyInstance, FastifyReply } from "fastify";
import { z } from "zod";
import { prisma } from "../db.js";
import {
  ReauthSchema,
  checkReauth,
  consentHeldElsewhere,
  eraseFamilyData,
  eraseParentAccount,
} from "../lib/accountDeletion.js";
import {
  DELETION_TOKEN_PATTERN,
  consumeDeletionLink,
  dropDeletionLink,
  findLiveDeletionLink,
  issueDeletionLink,
} from "../lib/accountDeletionLink.js";
import { appPublicUrl, getEmailSender } from "../lib/email/index.js";
import { accountDeletionEmail } from "../lib/email/templates.js";
import { AUTH_RATE_LIMIT } from "../lib/rateLimits.js";

/**
 * #442 PR 3: account deletion from a web link (design §7, comment 6495864112). Google Play requires the
 * listing to name a URL where an account can be deleted without the app. The API serves the pages
 * itself, as it does the digest-confirm page (`routes/digests.ts`), so the link works wherever the API
 * does and no second site has to be deployed.
 *
 *  - `GET  /v1/account/delete` — the public page: the in-app steps, what is deleted and kept, and a form
 *    that asks for the account's email.
 *  - `POST /v1/account/deletion-request {email}` — always `202` with the same body, before the address
 *    is even looked up, so it cannot tell anyone whether an account exists. A known address is mailed a
 *    30-minute single-use link.
 *  - `GET  /v1/account/delete/confirm?token=` — the page the link opens. It asks for the password (and
 *    the authenticator code when MFA is on) and spends nothing.
 *  - `POST /v1/account/delete/confirm` — checks the password with `checkReauth`, spends the link, and
 *    runs the same erase as the app: the owner deletes the whole family (`eraseFamilyData`, as
 *    `DELETE /v1/family`), anyone else only their own account (`eraseParentAccount`, as `DELETE /v1/me`).
 *
 * No route takes a session. The two POSTs carry `AUTH_RATE_LIMIT` (fails closed), the same brake as
 * `/login` and the in-app deletion, so the confirm page is no faster a password oracle than `/login`.
 */

const RequestSchema = z.object({
  // `/login`'s normalisation (routes/auth.ts LoginSchema): validated, then trimmed and lower-cased.
  email: z.string().max(320).email().transform((e) => e.trim().toLowerCase()),
});

/** The one body `POST /deletion-request` ever answers JSON callers with, known address or not. */
export const DELETION_REQUEST_ACCEPTED = { accepted: true } as const;

/**
 * The mail work a request started, so a test (or a graceful shutdown) can wait for it. The route never
 * awaits it: answering first is what keeps a known and an unknown address indistinguishable in time.
 */
const inFlight = new Set<Promise<void>>();

export async function settleDeletionRequests(): Promise<void> {
  await Promise.allSettled([...inFlight]);
}

async function mailDeletionLink(email: string, log: FastifyBaseLogger): Promise<void> {
  const issued = await issueDeletionLink(email);
  if (!issued) return;
  const link = `${appPublicUrl()}/v1/account/delete/confirm?token=${encodeURIComponent(issued.token)}`;
  const result = await getEmailSender()
    .send(accountDeletionEmail(issued.email, { link }))
    .catch((err: unknown) => ({ ok: false as const, reason: (err as Error)?.message ?? "send failed" }));
  if (result.ok) return;
  // The reason is the provider's answer; neither it nor this line carries the link.
  log.error({ reason: result.reason }, "account deletion email failed");
  // No mail left, so the link is not live: drop it, and the parent can ask again without the cooldown.
  await dropDeletionLink(issued.token).catch((err: unknown) => log.error({ err }, "could not drop an unsent deletion link"));
}

// ---------------------------------------------------------------------------------------------------
// Pages. English and Arabic on every page, the Arabic block right-to-left, as `resultPage` does in
// routes/digests.ts. Nothing user-supplied is ever rendered: the only dynamic value is the token, which
// is checked against DELETION_TOKEN_PATTERN (hex) first and escaped anyway.
// ---------------------------------------------------------------------------------------------------

function esc(s: string): string {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}

const CARD = "background:#fff;border-radius:8px;padding:24px;margin-top:16px";
const BUTTON = "border:0;padding:12px 18px;border-radius:8px;font-size:16px;color:#fff";
const INPUT = "display:block;width:100%;box-sizing:border-box;padding:10px;margin:4px 0 12px;font-size:16px;border:1px solid #c5c9d6;border-radius:6px";

function page(en: string, ar: string): string {
  return `<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="referrer" content="no-referrer"><title>OSRA · أسرة</title></head>
<body style="margin:0;background:#f6f7fb;font-family:-apple-system,Segoe UI,Roboto,Arial,sans-serif;color:#1f2430">
  <div style="max-width:560px;margin:0 auto;padding:8px 16px 24px">
    <div lang="en" dir="ltr" style="${CARD}">${en}</div>
    <div lang="ar" dir="rtl" style="${CARD}">${ar}</div>
  </div>
</body>
</html>`;
}

const h = (text: string) => `<h2 style="margin:0 0 12px;font-size:20px">${text}</h2>`;
const p = (text: string) => `<p style="margin:0 0 12px;line-height:1.5">${text}</p>`;
const err = (text: string | undefined) =>
  text ? `<p role="alert" style="margin:0 0 12px;padding:10px;border-radius:6px;background:#fdecea;color:#8a1c12;line-height:1.5">${text}</p>` : "";

/**
 * Every page: never cached (the confirm page holds the token in its form), never sent as a referrer,
 * never framed (a framed delete button is a clickjacking target), and no script at all.
 */
function sendPage(reply: FastifyReply, status: number, html: string): FastifyReply {
  return reply
    .code(status)
    .type("text/html; charset=utf-8")
    .header("cache-control", "no-store")
    .header("referrer-policy", "no-referrer")
    .header("x-content-type-options", "nosniff")
    .header(
      "content-security-policy",
      "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'",
    )
    .send(html);
}

type Copy = { en: string; ar: string };

const REQUEST_ERRORS = {
  invalid_email: { en: "Enter the email address you sign in with.", ar: "أدخل البريد الإلكتروني الذي تسجّل الدخول به." },
} satisfies Record<string, Copy>;

function publicPage(error?: Copy): string {
  const form = (lang: "en" | "ar") => {
    const label = lang === "en" ? "Your account's email" : "البريد الإلكتروني لحسابك";
    const button = lang === "en" ? "Email me a deletion link" : "أرسل لي رابط الحذف";
    return `<form method="post" action="/v1/account/deletion-request">
      <label style="display:block">${label}<input type="email" name="email" required maxlength="320" autocomplete="email" style="${INPUT}"></label>
      <button type="submit" style="${BUTTON};background:#3949ab">${button}</button>
    </form>`;
  };
  const en = [
    h("Delete your OSRA account"),
    err(error?.en),
    p("<strong>In the app:</strong> open OSRA, go to Settings, then Delete account. Enter your password, and your authenticator code if two-step sign-in is on, and confirm."),
    p("<strong>If you created the family</strong> (the owner), this deletes the whole family: every child's activity, locations, alerts, rules and linked phones, and every other parent's and guardian's access. <strong>If you joined someone else's family</strong>, it deletes only your own account; the family and the children stay."),
    p("<strong>What is kept:</strong> the IDs of signed-out sessions until those sessions would have expired (at most 8 days), encrypted database backups until they rotate out, and server logs, which hold IDs but no messages or content, until their retention ends. Everything else is deleted at once. There is no undo."),
    p("<strong>Without the app:</strong> enter your account's email. If an account uses it, we send a link that works once, for 30 minutes. The link asks for your password (and authenticator code) before anything is deleted."),
    form("en"),
  ].join("");
  const ar = [
    h("حذف حسابك في أسرة"),
    err(error?.ar),
    p("<strong>من التطبيق:</strong> افتح أسرة، ثم الإعدادات، ثم حذف الحساب. أدخل كلمة المرور، ورمز تطبيق المصادقة إن كان التحقق بخطوتين مفعّلاً، ثم أكّد."),
    p("<strong>إن كنت أنت من أنشأ العائلة</strong> (المالك)، فسيُحذف كل شيء في العائلة: نشاط كل طفل ومواقعه وتنبيهاته وقواعده والهواتف المرتبطة، ووصول كل والد أو وصيّ آخر. <strong>وإن كنت قد انضممت إلى عائلة غيرك</strong>، فسيُحذف حسابك أنت فقط، وتبقى العائلة والأطفال."),
    p("<strong>ما يُحتفظ به:</strong> معرّفات الجلسات التي سُجّل الخروج منها حتى ينتهي وقتها (8 أيام على الأكثر)، والنسخ الاحتياطية المشفّرة لقاعدة البيانات حتى تُستبدل، وسجلات الخادم التي تحوي معرّفات دون أي رسائل أو محتوى حتى تنتهي مدة حفظها. ويُحذف كل ما عدا ذلك فوراً، ولا يمكن التراجع."),
    p("<strong>من دون التطبيق:</strong> أدخل البريد الإلكتروني لحسابك. إن كان هناك حساب يستخدمه، نرسل إليه رابطاً صالحاً لمرة واحدة ولمدة 30 دقيقة. يطلب الرابط كلمة المرور (ورمز المصادقة) قبل حذف أي شيء."),
    form("ar"),
  ].join("");
  return page(en, ar);
}

/** The answer to every well-formed request, known address or not. It echoes nothing back. */
function requestAcceptedPage(): string {
  return page(
    h("Check your email") +
      p("If an OSRA account uses that address, we have sent it a link. It works once and expires in 30 minutes. If nothing arrives, check your spam folder, or ask again in a minute."),
    h("تحقّق من بريدك الإلكتروني") +
      p("إن كان هناك حساب في أسرة يستخدم هذا العنوان، فقد أرسلنا إليه رابطاً. الرابط صالح لمرة واحدة وتنتهي صلاحيته خلال 30 دقيقة. إن لم يصلك شيء، تحقّق من مجلد الرسائل غير المرغوب فيها، أو أعد الطلب بعد دقيقة."),
  );
}

/** Unknown, used, expired and malformed links: one page, so it tells a caller nothing about a token. */
function expiredPage(): string {
  return page(
    h("This link has expired or was already used") +
      p('Nothing was deleted. <a href="/v1/account/delete">Ask for a new link</a>.'),
    h("انتهت صلاحية هذا الرابط أو سبق استخدامه") +
      p('لم يُحذف شيء. <a href="/v1/account/delete">اطلب رابطاً جديداً</a>.'),
  );
}

const CONFIRM_ERRORS = {
  reauth_failed: {
    en: "That password or authenticator code is not right. Nothing was deleted.",
    ar: "كلمة المرور أو رمز المصادقة غير صحيح. لم يُحذف شيء.",
  },
  mfa_reenroll_required: {
    en: "Two-step sign-in is on for this account, but no authenticator is set up. Sign in to the app and set one up first. Nothing was deleted.",
    ar: "التحقق بخطوتين مفعّل لهذا الحساب، لكن لا يوجد تطبيق مصادقة مُعدّ. سجّل الدخول إلى التطبيق وأعدّ واحداً أولاً. لم يُحذف شيء.",
  },
  password_required: { en: "Enter your password.", ar: "أدخل كلمة المرور." },
  consent_records_held: {
    en: "This account still holds a parental consent record for a child in another family. Withdraw it in the app first. Nothing was deleted.",
    ar: "ما زال هذا الحساب يحمل سجلّ موافقة أبوية لطفل في عائلة أخرى. اسحبه من التطبيق أولاً. لم يُحذف شيء.",
  },
} satisfies Record<string, Copy>;

type ConfirmError = keyof typeof CONFIRM_ERRORS;

function confirmPage(token: string, who: { owner: boolean; mfa: boolean }, error?: ConfirmError): string {
  const form = (lang: "en" | "ar") => {
    const en = lang === "en";
    const button = who.owner
      ? en ? "Delete the family and all its data" : "حذف العائلة وكل بياناتها"
      : en ? "Delete my account" : "حذف حسابي";
    const mfa = who.mfa
      ? `<label style="display:block">${en ? "Authenticator code" : "رمز تطبيق المصادقة"}<input name="mfaCode" required inputmode="numeric" pattern="[0-9 ]{6,7}" maxlength="7" autocomplete="one-time-code" style="${INPUT}"></label>`
      : "";
    return `<form method="post" action="/v1/account/delete/confirm">
      <input type="hidden" name="token" value="${esc(token)}">
      <label style="display:block">${en ? "Password" : "كلمة المرور"}<input type="password" name="password" required maxlength="256" autocomplete="current-password" style="${INPUT}"></label>
      ${mfa}
      <button type="submit" style="${BUTTON};background:#b3261e">${button}</button>
    </form>`;
  };
  const copy = error ? CONFIRM_ERRORS[error] : undefined;
  const en = [
    h(who.owner ? "Delete the family and all its data" : "Delete your OSRA account"),
    err(copy?.en),
    p(
      who.owner
        ? "You own this family, so this deletes all of it: every child's activity, locations, alerts, rules and linked phones, and every other parent's and guardian's access. Every linked phone is unlinked."
        : "This deletes only your own account. The family, its children and the other parents stay.",
    ),
    p("This cannot be undone. Enter your password to confirm."),
    form("en"),
  ].join("");
  const ar = [
    h(who.owner ? "حذف العائلة وكل بياناتها" : "حذف حسابك في أسرة"),
    err(copy?.ar),
    p(
      who.owner
        ? "أنت مالك هذه العائلة، لذا سيُحذف كل شيء فيها: نشاط كل طفل ومواقعه وتنبيهاته وقواعده والهواتف المرتبطة، ووصول كل والد أو وصيّ آخر. ويُفصل كل هاتف مرتبط."
        : "سيُحذف حسابك أنت فقط. تبقى العائلة وأطفالها والوالدان الآخران.",
    ),
    p("لا يمكن التراجع عن ذلك. أدخل كلمة المرور للتأكيد."),
    form("ar"),
  ].join("");
  return page(en, ar);
}

function deletedPage(family: boolean): string {
  return page(
    h("Deleted") +
      p(family
        ? "The family and all its data have been deleted, and every parent and guardian has been signed out."
        : "Your account has been deleted and you have been signed out everywhere. The family and its children stay.") +
      p("You can uninstall the app."),
    h("تم الحذف") +
      p(family
        ? "حُذفت العائلة وكل بياناتها، وسُجّل خروج كل والد ووصيّ."
        : "حُذف حسابك وسُجّل خروجك من كل الأجهزة. تبقى العائلة وأطفالها.") +
      p("يمكنك الآن إزالة التطبيق."),
  );
}

/** The erase threw after the link was spent. Every erase step is idempotent, so a new link finishes it. */
function failedPage(): string {
  return page(
    h("The deletion did not finish") +
      p('Something went wrong on our side. <a href="/v1/account/delete">Ask for a new link</a> and try again; the deletion picks up where it stopped.'),
    h("لم يكتمل الحذف") +
      p('حدث خطأ من جهتنا. <a href="/v1/account/delete">اطلب رابطاً جديداً</a> وحاول مرة أخرى، وسيُكمل الحذف من حيث توقف.'),
  );
}

const isForm = (contentType: string | undefined) => (contentType ?? "").startsWith("application/x-www-form-urlencoded");

const str = (value: unknown): string | undefined => (typeof value === "string" ? value : undefined);

export async function accountRoutes(app: FastifyInstance) {
  // The pages' <form>s post as application/x-www-form-urlencoded, which Fastify has no parser for (see
  // routes/digests.ts). Unlike the digest page these forms carry fields, so the body is parsed. Registered
  // inside this plugin, so only /v1/account accepts the type.
  app.addContentTypeParser(
    "application/x-www-form-urlencoded",
    { parseAs: "string", bodyLimit: 4096 },
    (_req, body, done) => done(null, Object.fromEntries(new URLSearchParams(body as string))),
  );

  app.get("/delete", async (_req, reply) => sendPage(reply, 200, publicPage()));

  /**
   * Always `202` and always the same body for a well-formed address (design §7): the lookup, the token
   * and the mail run **after** the answer, so neither the status, the body nor the time to answer says
   * whether an account uses the address. A malformed address is `400`, which says nothing about any
   * account.
   */
  app.post("/deletion-request", { config: { rateLimit: AUTH_RATE_LIMIT } }, async (req, reply) => {
    const fromForm = isForm(req.headers["content-type"]);
    const parsed = RequestSchema.safeParse(req.body ?? {});
    if (!parsed.success) {
      return fromForm
        ? sendPage(reply, 400, publicPage(REQUEST_ERRORS.invalid_email))
        : reply.code(400).send({ error: "invalid_email" });
    }
    const work = mailDeletionLink(parsed.data.email, req.log).catch((e: unknown) =>
      req.log.error({ err: e }, "account deletion request failed"),
    );
    inFlight.add(work);
    void work.finally(() => inFlight.delete(work));
    return fromForm ? sendPage(reply, 202, requestAcceptedPage()) : reply.code(202).send(DELETION_REQUEST_ACCEPTED);
  });

  /** The page the mailed link opens. It spends nothing: a mail scanner following the link changes nothing. */
  app.get("/delete/confirm", async (req, reply) => {
    const token = str((req.query as { token?: unknown } | undefined)?.token) ?? "";
    if (!DELETION_TOKEN_PATTERN.test(token)) return sendPage(reply, 400, expiredPage());
    const link = await findLiveDeletionLink(token);
    const parent = link ? await prisma.parent.findUnique({ where: { id: link.parentId } }) : null;
    if (!link || !parent) return sendPage(reply, 404, expiredPage());
    return sendPage(reply, 200, confirmPage(token, { owner: parent.role === "owner", mfa: parent.mfaEnabled }));
  });

  /**
   * Delete. The order is the point:
   * 1. the link must be live (else the expired page);
   * 2. the password, and the code when MFA is on, must pass `checkReauth` — a wrong one shows the form
   *    again and **leaves the link usable**, while the route's rate limit counts the attempt;
   * 3. the same `409 consent_records_held` refusal as the app, before anything is spent;
   * 4. the link is spent by one conditional update, so of two racing submits only one continues;
   * 5. the erase PR 1's routes run, chosen by the role read now, not when the link was mailed.
   */
  app.post("/delete/confirm", { config: { rateLimit: AUTH_RATE_LIMIT } }, async (req, reply) => {
    const body = (req.body ?? {}) as Record<string, unknown>;
    const token = str(body.token) ?? "";
    if (!DELETION_TOKEN_PATTERN.test(token)) return sendPage(reply, 400, expiredPage());
    const link = await findLiveDeletionLink(token);
    const parent = link ? await prisma.parent.findUnique({ where: { id: link.parentId } }) : null;
    if (!link || !parent) return sendPage(reply, 404, expiredPage());

    const who = { owner: parent.role === "owner", mfa: parent.mfaEnabled };
    // A browser sends an empty field for an unused input, and people type a code as "123 456".
    const mfaCode = str(body.mfaCode)?.replace(/\s+/g, "") || undefined;
    const reauth = ReauthSchema.safeParse({ password: str(body.password) ?? "", mfaCode });
    if (!reauth.success) {
      const error: ConfirmError = reauth.error.issues.some((i) => i.path[0] === "password") ? "password_required" : "reauth_failed";
      return sendPage(reply, 400, confirmPage(token, who, error));
    }
    const refusal = await checkReauth(parent, reauth.data);
    if (refusal) return sendPage(reply, 401, confirmPage(token, who, refusal));

    const parentIds = who.owner
      ? (await prisma.parent.findMany({ where: { familyId: parent.familyId }, select: { id: true } })).map((row) => row.id)
      : [parent.id];
    if ((await consentHeldElsewhere(parentIds, parent.familyId)) > 0) {
      return sendPage(reply, 409, confirmPage(token, who, "consent_records_held"));
    }

    if (!(await consumeDeletionLink(link.id))) return sendPage(reply, 404, expiredPage());
    try {
      if (who.owner) await eraseFamilyData(parent.familyId);
      else await eraseParentAccount(parent);
    } catch (e) {
      req.log.error({ err: e }, "account deletion from the web link failed after the link was spent");
      return sendPage(reply, 500, failedPage());
    }
    return sendPage(reply, 200, deletedPage(who.owner));
  });
}
