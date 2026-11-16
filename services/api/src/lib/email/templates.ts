import type { EmailMessage } from "./index.js";

/**
 * Email templates. Bilingual (English + Arabic) by default: the product's first market is
 * Arabic-speaking families and the parent app has no locale preference yet, so every message
 * carries both. When a parent locale exists, pass it and the other language is dropped.
 */

export type Locale = "en" | "ar" | "both";

function esc(s: string): string {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}

/**
 * Longest piece of a stored row this file will put in a subject or a body (roadmap 2.7,
 * osra-security#2). The writes are bounded too (`register`, `PATCH /family/children/:id`), but a row
 * created before that bound — or by any future caller that forgets it — must not be able to stretch a
 * subject line. Truncation is by code point, so an Arabic letter or an emoji is never cut in half.
 */
export const MAX_OUTBOUND_TEXT = 80;

function clip(value: string, max = MAX_OUTBOUND_TEXT): string {
  const points = Array.from(value ?? "");
  return points.length > max ? points.slice(0, max).join("") : points.join("");
}

type TextPart = string | { text: string; html: string };
type EmailSection = { title: TextPart; body: TextPart[]; cta?: { label: string; href: string } };

function htmlPart(part: TextPart): string {
  return typeof part === "string" ? esc(part) : part.html;
}

function textPart(part: TextPart): string {
  return typeof part === "string" ? part : part.text;
}

function htmlName(value: string): string {
  return `<bdi>${esc(clip(value))}</bdi>`;
}

function textName(value: string): string {
  return `\u2068${clip(value)}\u2069`;
}

function shell(parts: { en: EmailSection; ar: EmailSection }, locale: Locale) {
  const block = (dir: "ltr" | "rtl", t: EmailSection) => `
    <div dir="${dir}" style="font-family:-apple-system,Segoe UI,Roboto,Arial,sans-serif;max-width:560px;margin:0 auto;padding:24px;color:#1f2430">
      <h2 style="margin:0 0 12px;font-size:20px">${htmlPart(t.title)}</h2>
      ${t.body.map((p) => `<p style="margin:0 0 12px;line-height:1.5">${htmlPart(p)}</p>`).join("")}
      ${t.cta ? `<p style="margin:20px 0"><a href="${esc(t.cta.href)}" style="background:#3949ab;color:#fff;text-decoration:none;padding:12px 18px;border-radius:8px;display:inline-block">${esc(t.cta.label)}</a></p><p style="font-size:12px;color:#667">${esc(t.cta.href)}</p>` : ""}
    </div>`;
  const text = (t: EmailSection) =>
    [textPart(t.title), "", ...t.body.map(textPart), ...(t.cta ? ["", `${t.cta.label}: ${t.cta.href}`] : [])].join("\n");
  const en = locale !== "ar";
  const ar = locale !== "en";
  return {
    html: `<!doctype html><html><body style="margin:0;background:#f6f7fb;padding:16px 0">${en ? block("ltr", parts.en) : ""}${en && ar ? '<hr style="border:0;border-top:1px solid #e3e6ef;max-width:560px">' : ""}${ar ? block("rtl", parts.ar) : ""}<p style="text-align:center;font-size:11px;color:#99a">OSRA · أسرة</p></body></html>`,
    text: [en ? text(parts.en) : "", en && ar ? "\n----\n" : "", ar ? text(parts.ar) : ""].join(""),
  };
}

export function passwordResetEmail(to: string, link: string, locale: Locale = "both"): EmailMessage {
  const { html, text } = shell(
    {
      en: {
        title: "Reset your OSRA password",
        body: ["We received a request to reset the password for this account. The link below works for 15 minutes.", "If you did not ask for this, you can ignore this email; your password will not change."],
        cta: { label: "Choose a new password", href: link },
      },
      ar: {
        title: "إعادة تعيين كلمة مرور حسابك في تطبيق أسرة",
        body: ["وصلنا طلب لإعادة تعيين كلمة المرور لهذا الحساب. الرابط أدناه صالح لمدة 15 دقيقة.", "إذا لم تطلب ذلك، فتجاهل هذه الرسالة، ولن تتغيّر كلمة المرور."],
        cta: { label: "اختيار كلمة مرور جديدة", href: link },
      },
    },
    locale,
  );
  return { to, subject: "Reset your OSRA password · إعادة تعيين كلمة مرور حسابك في تطبيق أسرة", html, text };
}

/**
 * ADR-0023: a recovery code was used. It states what happened and what the parent must do, and it
 * carries **no link**: the support path (Option B) is not decided, so inviting a click would promise
 * a channel that does not exist. It never carries the code itself either.
 */
export function mfaRecoveredEmail(to: string, locale: Locale = "both"): EmailMessage {
  const { html, text } = shell(
    {
      en: {
        title: "A recovery code was used on your OSRA account",
        body: [
          "Someone used one of your MFA recovery codes to reset the second factor. Your authenticator has been removed, your recovery codes are no longer valid, and every session has been signed out.",
          "If that was you, sign in with your password and set up a new authenticator; you will receive a fresh set of recovery codes.",
          "If it was not you, change your password immediately. Whoever did this also had your password.",
        ],
      },
      ar: {
        title: "تم استخدام رمز استرداد لحسابك في تطبيق أسرة",
        body: [
          "استُخدم أحد رموز الاسترداد الخاصة بحسابك لإيقاف التحقق بخطوتين. أُزيل تطبيق المصادقة من الحساب، ولم تعد رموز الاسترداد صالحة، وسُجّل الخروج من كل الأجهزة.",
          "إذا كنت أنت من فعل ذلك، فسجّل الدخول بكلمة المرور وأعِدّ تطبيق مصادقة جديدًا، وستحصل على مجموعة جديدة من رموز الاسترداد.",
          "إذا لم تكن أنت، فغيّر كلمة المرور فورًا، فمن فعل ذلك يعرف كلمة مرورك أيضًا.",
        ],
      },
    },
    locale,
  );
  return { to, subject: "MFA recovery used on your OSRA account · تم استخدام رمز استرداد لحسابك في تطبيق أسرة", html, text };
}

function optionalName(value: string | null): string | null {
  const trimmed = value?.trim();
  return trimmed ? clip(trimmed) : null;
}

export function inviteEmail(to: string, opts: { inviterName: string | null; familyName: string | null; role: string; link: string }, locale: Locale = "both"): EmailMessage {
  const inviterName = optionalName(opts.inviterName);
  const familyName = optionalName(opts.familyName);
  const titleEn: TextPart = inviterName
    ? familyName
      ? {
          text: `${textName(inviterName)} invited you to the ${textName(familyName)} family on OSRA`,
          html: `${htmlName(inviterName)} invited you to the ${htmlName(familyName)} family on OSRA`,
        }
      : {
          text: `${textName(inviterName)} invited you to a family on OSRA`,
          html: `${htmlName(inviterName)} invited you to a family on OSRA`,
        }
    : familyName
      ? {
          text: `You have been invited to the ${textName(familyName)} family on OSRA`,
          html: `You have been invited to the ${htmlName(familyName)} family on OSRA`,
        }
      : "You have been invited to a family on OSRA";
  const titleAr: TextPart = inviterName
    ? familyName
      ? {
          text: `دعوة من ${textName(inviterName)} للانضمام إلى عائلة ${textName(familyName)} في تطبيق أسرة`,
          html: `دعوة من ${htmlName(inviterName)} للانضمام إلى عائلة ${htmlName(familyName)} في تطبيق أسرة`,
        }
      : {
          text: `دعوة من ${textName(inviterName)} للانضمام إلى عائلة في تطبيق أسرة`,
          html: `دعوة من ${htmlName(inviterName)} للانضمام إلى عائلة في تطبيق أسرة`,
        }
    : familyName
      ? {
          text: `دعوة للانضمام إلى عائلة ${textName(familyName)} في تطبيق أسرة`,
          html: `دعوة للانضمام إلى عائلة ${htmlName(familyName)} في تطبيق أسرة`,
        }
      : "دعوة للانضمام إلى عائلة في تطبيق أسرة";
  const roleEn = opts.role === "co-parent" || opts.role === "guardian"
    ? `You have been invited as a ${opts.role}. Accept to see the family's children, alerts and controls from your own account.`
    : "You have been invited to join the family. Accept to see the family's children, alerts and controls from your own account.";
  const roleAr = opts.role === "co-parent"
    ? "تمت دعوتك بصفة والد مشارك. اقبل الدعوة لمتابعة الأطفال والتنبيهات وأدوات التحكم من حسابك."
    : opts.role === "guardian"
      ? "تمت دعوتك بصفة وليّ أمر. اقبل الدعوة لمتابعة الأطفال والتنبيهات وأدوات التحكم من حسابك."
      : "تمت دعوتك للانضمام إلى العائلة. اقبل الدعوة لمتابعة الأطفال والتنبيهات وأدوات التحكم من حسابك.";
  const { html, text } = shell(
    {
      en: {
        title: titleEn,
        body: [roleEn, "The invitation expires in 7 days."],
        cta: { label: "Accept invitation", href: opts.link },
      },
      ar: {
        title: titleAr,
        body: [roleAr, "تنتهي صلاحية الدعوة خلال 7 أيام."],
        cta: { label: "قبول الدعوة", href: opts.link },
      },
    },
    locale,
  );
  return {
    to,
    subject: familyName ? `Invitation to ${textName(familyName)} on OSRA · دعوة إلى عائلة في تطبيق أسرة` : "Invitation to a family on OSRA · دعوة إلى عائلة في تطبيق أسرة",
    html,
    text,
    idempotencyKey: `invite:${opts.link}`,
  };
}

export interface DigestChild {
  displayName: string;
  totalAppMinutes: number;
  topApps: Array<{ name: string; minutes: number }>;
  urlVisits: number;
  topBlockedDomains: Array<{ domain: string; count: number }>;
  socialConcerns: number;
  calls: number;
  sms: number;
}

function countEn(value: number, singular: string, plural = `${singular}s`): string {
  return `${value} ${new Intl.PluralRules("en").select(value) === "one" ? singular : plural}`;
}

function screenAr(value: number): string {
  switch (new Intl.PluralRules("ar").select(value)) {
    case "zero": return "لا يوجد";
    case "one": return "دقيقة واحدة";
    case "two": return "دقيقتان";
    case "few": return `${value} دقائق`;
    default: return `${value} دقيقة`;
  }
}

/** An app in the list was used, so zero rounded minutes is "less than a minute", never "nothing". Whole words, no unit letter (R3). */
function appMinutesAr(value: number): string {
  return value === 0 ? "أقل من دقيقة" : screenAr(value);
}

function periodAr(days: number, familyName: string): TextPart {
  const category = new Intl.PluralRules("ar").select(days);
  const suffix = days === 1 ? "اليوم"
    : days === 2 ? "آخر يومين"
      : category === "few" ? `آخر ${days} أيام`
        : category === "many" ? `آخر ${days} يومًا`
          : `آخر ${days} يوم`;
  return {
    text: `ملخّص عائلة ${textName(familyName)} من تطبيق أسرة: ${suffix}`,
    html: `ملخّص عائلة ${htmlName(familyName)} من تطبيق أسرة: ${suffix}`,
  };
}

export function digestEmail(to: string | string[], opts: { familyName: string; days: number; children: DigestChild[]; link: string }, locale: Locale = "both"): EmailMessage {
  const familyName = clip(opts.familyName);
  const periodEn = opts.days === 1 ? "today" : `the last ${countEn(opts.days, "day")}`;
  const lineEn = (c: DigestChild) =>
    `${clip(c.displayName)}: ${countEn(c.totalAppMinutes, "min", "min")} on screen; top apps ${c.topApps.map((a) => `${a.name} ${a.minutes}m`).join(", ") || "none"}; ${countEn(c.urlVisits, "site")} visited, ${c.topBlockedDomains.length} blocked; ${countEn(c.socialConcerns, "social concern")}; ${countEn(c.calls, "call")}, ${countEn(c.sms, "SMS", "SMS")}.`;
  const lineAr = (c: DigestChild): TextPart => {
    const apps = c.topApps.map((app) => ({
      text: `${textName(app.name)} ${appMinutesAr(app.minutes)}`,
      html: `${htmlName(app.name)} ${appMinutesAr(app.minutes)}`,
    }));
    const appsText = apps.length
      ? { text: apps.map((app) => app.text).join("، "), html: apps.map((app) => app.html).join("، ") }
      : { text: "لا يوجد", html: "لا يوجد" };
    return {
      text: `${textName(c.displayName)} — وقت الشاشة: ${screenAr(c.totalAppMinutes)}؛ أكثر التطبيقات استخدامًا: ${appsText.text}؛ المواقع التي فُتحت: ${c.urlVisits}؛ المواقع المحجوبة: ${c.topBlockedDomains.length}؛ تنبيهات وسائل التواصل الاجتماعي: ${c.socialConcerns}؛ المكالمات: ${c.calls}؛ الرسائل النصية: ${c.sms}.`,
      html: `${htmlName(c.displayName)} — وقت الشاشة: ${screenAr(c.totalAppMinutes)}؛ أكثر التطبيقات استخدامًا: ${appsText.html}؛ المواقع التي فُتحت: ${c.urlVisits}؛ المواقع المحجوبة: ${c.topBlockedDomains.length}؛ تنبيهات وسائل التواصل الاجتماعي: ${c.socialConcerns}؛ المكالمات: ${c.calls}؛ الرسائل النصية: ${c.sms}.`,
    };
  };
  const { html, text } = shell(
    {
      en: { title: `OSRA digest for ${familyName} — ${periodEn}`, body: opts.children.length ? opts.children.map(lineEn) : ["No activity was recorded."], cta: { label: "Open the dashboard", href: opts.link } },
      ar: { title: periodAr(opts.days, familyName), body: opts.children.length ? opts.children.map(lineAr) : ["لم يُسجَّل أي نشاط."], cta: { label: "فتح لوحة التحكم", href: opts.link } },
    },
    locale,
  );
  return { to, subject: `OSRA digest · ملخّص تطبيق أسرة — ${textName(familyName)}`, html, text };
}

/**
 * Roadmap 2.7 (osra-security#2): the address was added to a family's digest by a parent and must prove
 * it wants it. It states what will happen and carries the single-use 24-hour link.
 *
 * It carries **no user-written text** — not the family name, not a child's, nothing a parent typed — and
 * nothing about the family's children. The message goes to an address that has agreed to nothing: it must
 * not be usable to put a chosen string in a stranger's inbox (review of #354, item 2).
 */
export function digestConfirmEmail(to: string, opts: { link: string }, locale: Locale = "both"): EmailMessage {
  const { html, text } = shell(
    {
      en: {
        title: "Confirm an OSRA family digest",
        body: [
          "A parent added this address to the family's OSRA digest. Nothing is sent here until you confirm, and you can ignore this message if you do not want it.",
          "The link works once and expires in 24 hours.",
        ],
        cta: { label: "Confirm this address", href: opts.link },
      },
      ar: {
        title: "تأكيد استلام ملخّص عائلة من تطبيق أسرة",
        body: [
          "أضاف أحد الوالدين هذا العنوان إلى قائمة مستلمي ملخّص العائلة في تطبيق أسرة. لن يُرسَل إليه شيء حتى تؤكّد ذلك، ويمكنك تجاهل هذه الرسالة إن لم ترغب في استلام الملخّص.",
          "الرابط صالح لمرة واحدة وتنتهي صلاحيته خلال 24 ساعة.",
        ],
        cta: { label: "تأكيد هذا العنوان", href: opts.link },
      },
    },
    locale,
  );
  return { to, subject: `Confirm your OSRA digest · تأكيد استلام ملخّص من تطبيق أسرة`, html, text };
}

/**
 * #442 PR 3 (Play account deletion, the web link): someone asked, on the public page, to delete the
 * account that uses this address. The link opens a page that asks for the password (and the
 * authenticator code when MFA is on) before anything is deleted, so the mail alone deletes nothing.
 *
 * Like `digestConfirmEmail`, it carries **no user-written text**: the request came from a page anyone
 * can reach, so the message must not be a way to put a chosen string in an account holder's inbox.
 */
export function accountDeletionEmail(to: string, opts: { link: string }, locale: Locale = "both"): EmailMessage {
  const { html, text } = shell(
    {
      en: {
        title: "Delete your OSRA account",
        body: [
          "Someone asked to delete the OSRA account that uses this address. If it was you, open the link and enter your password to confirm. Nothing is deleted until you do.",
          "The link works once and expires in 30 minutes. If you did not ask for this, ignore this email: your account stays as it is.",
        ],
        cta: { label: "Delete my account", href: opts.link },
      },
      ar: {
        title: "حذف حسابك في تطبيق أسرة",
        body: [
          "وصلنا طلب لحذف الحساب الذي يستخدم هذا العنوان في تطبيق أسرة. إن كنت أنت من طلب ذلك، فافتح الرابط وأدخل كلمة المرور للتأكيد. لن يُحذف شيء قبل ذلك.",
          "الرابط صالح لمرة واحدة وتنتهي صلاحيته خلال 30 دقيقة. إن لم تطلب ذلك، فتجاهل هذه الرسالة، وسيبقى حسابك كما هو.",
        ],
        cta: { label: "حذف حسابي", href: opts.link },
      },
    },
    locale,
  );
  return { to, subject: "Delete your OSRA account · حذف حسابك في تطبيق أسرة", html, text };
}
