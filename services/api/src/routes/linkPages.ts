import type { FastifyInstance, FastifyRequest } from "fastify";
import { prisma } from "../db.js";
import { ReauthSchema, checkReauth } from "../lib/accountDeletion.js";
import { BUTTON, INPUT, PRIMARY, err, esc, h, p, page, sendPage } from "../lib/htmlPage.js";
import { AUTH_RATE_LIMIT } from "../lib/rateLimits.js";
import { acceptInvite, findOpenInvite } from "./invites.js";

/**
 * #789: the pages the mailed links open. Every mail the API sends carries `APP_PUBLIC_URL` + a path, and
 * in production that address is the API itself, so the API serves the page, as it already does for
 * account deletion (`routes/account.ts`) and the digest confirmation (`routes/digests.ts`).
 *
 *  - `GET /reset?token=`              the new-password form        → `POST /reset`
 *  - `GET /mfa/reset/confirm?token=`  one button                   → `POST /mfa/reset/confirm`
 *  - `GET /mfa/reset/cancel?token=`   one button                   → `POST /mfa/reset/cancel`
 *  - `GET /invite/accept?token=`      the password form            → `POST /invite/accept`
 *  - `GET /dashboard`                 "open the app"
 *
 * Rules every route here keeps:
 *
 *  1. **A GET changes nothing.** Mail scanners and link previews follow links; only a person presses a
 *     button. Each GET reads at most, and the state change sits behind the POST.
 *  2. **One implementation of each state change.** The three auth POSTs call the existing JSON routes
 *     under `/v1/auth` in-process (`app.inject`) and turn the answer into a page, so the single-use
 *     consume, the supersession rule, the retry contract and the auth rate limit are the ones already
 *     tested there. The caller's address is passed on, so that limit counts the person and not the API
 *     talking to itself. The invite POST calls `acceptInvite`, the function the JSON route also calls.
 *  3. **The token leaves the address bar on the first POST** (a hidden field), is never rendered except
 *     into that field, and is checked against its own shape first. The request log already drops
 *     `?token=` (`lib/logRedaction.ts`), and `sendPage` sets no-store, no-referrer and a policy that
 *     loads nothing and runs no script.
 *  4. **Nothing user-supplied is rendered**: no names, no addresses.
 */

type Copy = { en: string; ar: string };

/** A signed token as `@fastify/jwt` writes it: three base64url parts. */
const JWT_PATTERN = /^[A-Za-z0-9_-]{1,1024}\.[A-Za-z0-9_-]{1,2048}\.[A-Za-z0-9_-]{1,1024}$/;
/** `FamilyInvite.id` is a uuid (schema.prisma). */
const INVITE_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const MIN_PASSWORD = 12; // `POST /v1/auth/reset/confirm` and `/register` both require 12

const str = (value: unknown): string | undefined => (typeof value === "string" ? value : undefined);
const queryToken = (req: FastifyRequest) => str((req.query as { token?: unknown } | undefined)?.token) ?? "";
const bodyOf = (req: FastifyRequest) => (req.body ?? {}) as Record<string, unknown>;

const hidden = (token: string) => `<input type="hidden" name="token" value="${esc(token)}">`;
// One colour for every button here. None of these pages destroys anything: cancelling an MFA reset is
// the safe action, so it is not red (UI/UX Bureau, #804).
const submit = (label: string) => `<button type="submit" style="${BUTTON};background:${PRIMARY}">${label}</button>`;

const COMMON = {
  unavailable: {
    en: "Something went wrong on our side. Nothing was changed. Try again in a minute.",
    ar: "حدث خطأ من جهتنا. لم يتغيّر شيء. حاول مرة أخرى بعد دقيقة.",
  },
  too_many: {
    en: "Too many attempts. Wait a minute and try again.",
    ar: "محاولات كثيرة جدًا. انتظر دقيقة ثم حاول مجددًا.",
  },
} satisfies Record<string, Copy>;

// --- Password reset ----------------------------------------------------------------------------------

const RESET_ERRORS = {
  mismatch: { en: "The two passwords are not the same.", ar: "كلمتا المرور غير متطابقتين." },
  too_short: { en: "The password must be at least 12 characters.", ar: "يجب أن تتكون كلمة المرور من 12 حرفًا على الأقل." },
  ...COMMON,
} satisfies Record<string, Copy>;

function resetPage(token: string, error?: Copy): string {
  const form = (en: boolean) => `<form method="post" action="/reset">
      ${hidden(token)}
      <label style="display:block">${en ? "New password" : "كلمة المرور الجديدة"}<input type="password" name="password" required minlength="${MIN_PASSWORD}" maxlength="256" autocomplete="new-password" style="${INPUT}"></label>
      <label style="display:block">${en ? "Repeat the new password" : "أعد كتابة كلمة المرور الجديدة"}<input type="password" name="passwordRepeat" required minlength="${MIN_PASSWORD}" maxlength="256" autocomplete="new-password" style="${INPUT}"></label>
      ${submit(en ? "Change password" : "تغيير كلمة المرور")}
    </form>`;
  return page(
    h("Choose a new password") +
      err(error?.en) +
      p("Use at least 12 characters. When you change it, every device is signed out, and you sign in again with the new password.") +
      form(true),
    h("اختيار كلمة مرور جديدة") +
      err(error?.ar) +
      p("استخدم 12 حرفًا على الأقل. عند تغيير كلمة المرور يُسجَّل خروجك من كل الأجهزة، ثم تسجّل الدخول بكلمة المرور الجديدة.") +
      form(false),
  );
}

const resetDonePage = () =>
  page(
    h("Password changed") + p("You have been signed out on every device. Open the OSRA app and sign in with your new password."),
    h("تم تغيير كلمة المرور") + p("سُجّل خروجك من كل الأجهزة. افتح تطبيق أسرة وسجّل الدخول بكلمة المرور الجديدة."),
  );

/** Unknown, used, superseded, expired and malformed links: one page, so it says nothing about a token. */
const resetExpiredPage = () =>
  page(
    h("This link has expired or was already used") + p("Nothing was changed. Open the OSRA app and ask for a new link."),
    h("انتهت صلاحية هذا الرابط أو سبق استخدامه") + p("لم يتغيّر شيء. افتح تطبيق أسرة واطلب رابطًا جديدًا."),
  );

// --- MFA reset (ADR-0031): the mailbox step and the cancel link --------------------------------------

function mfaConfirmPage(token: string, error?: Copy): string {
  const form = (en: boolean) => `<form method="post" action="/mfa/reset/confirm">${hidden(token)}${submit(en ? "Yes, continue the reset" : "نعم، متابعة إعادة التعيين")}</form>`;
  return page(
    h("Confirm the two-step verification reset") +
      err(error?.en) +
      p("We received a request to reset two-step verification for your OSRA account. If that was you, press the button to continue. The next steps are in the OSRA app.") +
      p("If it was not you, do not press it. Use the cancel link in the same email.") +
      form(true),
    h("تأكيد إعادة تعيين التحقق بخطوتين") +
      err(error?.ar) +
      p("وصلنا طلب لإعادة تعيين التحقق بخطوتين لحسابك في تطبيق أسرة. إن كنت أنت من طلب ذلك، فاضغط على الزر للمتابعة. الخطوات التالية في التطبيق.") +
      p("إن لم تكن أنت، فلا تضغط على الزر، واستخدم رابط الإلغاء في الرسالة نفسها.") +
      form(false),
  );
}

const mfaConfirmedPage = (witness: "device" | "parent") =>
  witness === "device"
    ? page(
        h("Confirmed") + p("A code is now shown on your child's phone. Go back to the OSRA app and enter it."),
        h("تم التأكيد") + p("يظهر الآن رمز على هاتف طفلك. عُد إلى تطبيق أسرة وأدخله."),
      )
    : page(
        h("Confirmed") + p("Another parent in your family must now approve the reset in their OSRA app."),
        h("تم التأكيد") + p("يجب الآن أن يوافق والد آخر في عائلتك على إعادة التعيين من تطبيق أسرة على هاتفه."),
      );

const mfaExpiredPage = () =>
  page(
    h("This link has expired or was already used") + p("Nothing was changed by this link. To reset two-step verification, start again in the OSRA app."),
    h("انتهت صلاحية هذا الرابط أو سبق استخدامه") + p("لم يغيّر هذا الرابط شيئًا. لإعادة تعيين التحقق بخطوتين، ابدأ من جديد في تطبيق أسرة."),
  );

const mfaNotOpenPage = () =>
  page(
    h("This request is no longer open") + p("Nothing was changed by this link."),
    h("لم يعد هذا الطلب قائمًا") + p("لم يغيّر هذا الرابط شيئًا."),
  );

/** The mailbox step was spent but no phone could be told to show the code; the request ends by itself. */
const mfaFailedPage = () =>
  page(
    h("The reset could not continue") + p("Something went wrong on our side. Open the OSRA app and start the reset again."),
    h("تعذّرت متابعة إعادة التعيين") + p("حدث خطأ من جهتنا. افتح تطبيق أسرة وابدأ إعادة التعيين من جديد."),
  );

function mfaCancelPage(token: string, error?: Copy): string {
  const form = (en: boolean) => `<form method="post" action="/mfa/reset/cancel">${hidden(token)}${submit(en ? "Cancel the reset" : "إلغاء إعادة التعيين")}</form>`;
  return page(
    h("Cancel the two-step verification reset") +
      err(error?.en) +
      p("Press the button to stop the reset. Your two-step verification stays exactly as it is.") +
      p("If you did not ask for the reset, someone knows your password. Change it in the OSRA app.") +
      form(true),
    h("إلغاء إعادة تعيين التحقق بخطوتين") +
      err(error?.ar) +
      p("اضغط على الزر لإيقاف إعادة التعيين. يبقى التحقق بخطوتين كما هو تمامًا.") +
      p("إن لم تكن أنت من طلب إعادة التعيين، فهناك من يعرف كلمة مرورك. غيّرها من تطبيق أسرة.") +
      form(false),
  );
}

const mfaCancelledPage = () =>
  page(
    h("The reset was cancelled") + p("Two-step verification stays as it was. If you did not ask for the reset, change your password in the OSRA app."),
    h("أُلغيت إعادة التعيين") + p("يبقى التحقق بخطوتين كما كان. إن لم تكن أنت من طلب إعادة التعيين، فغيّر كلمة مرورك من تطبيق أسرة."),
  );

/** The request had already finished, expired or been cancelled: the link stopped nothing, and says so. */
const mfaAlreadyClosedPage = () =>
  page(
    h("This request is already closed") + p("This link did not cancel it. If you did not ask for the reset, change your password in the OSRA app now."),
    h("سبق أن انتهى هذا الطلب") + p("لم يُلغِه هذا الرابط. إن لم تكن أنت من طلب إعادة التعيين، فغيّر كلمة مرورك من تطبيق أسرة الآن."),
  );

// --- Family invite -----------------------------------------------------------------------------------

const INVITE_ERRORS = {
  reauth_failed: {
    en: "That password or authenticator code is not right. Nothing was changed.",
    ar: "كلمة المرور أو رمز تطبيق المصادقة غير صحيح. لم يتغيّر شيء.",
  },
  mfa_reenroll_required: {
    en: "Two-step verification is on for this account, but no authenticator is set up. Sign in to the app and set one up first. Nothing was changed.",
    ar: "التحقق بخطوتين مفعّل في هذا الحساب، لكن لم يتم إعداد تطبيق مصادقة. سجّل الدخول إلى تطبيق أسرة أولًا لإعداد تطبيق مصادقة. لم يتغيّر شيء.",
  },
  password_required: { en: "Enter your password.", ar: "أدخل كلمة المرور." },
} satisfies Record<string, Copy>;

type InviteError = keyof typeof INVITE_ERRORS;

/** The invited address has no account yet: the app creates it, then this same link finishes the job. */
const inviteNoAccountPage = () =>
  page(
    h("You are invited to a family on OSRA") +
      p("First create your account: install the OSRA app and sign up with the email address this invitation was sent to.") +
      p("Then open this link again to join the family. The invitation is valid for 7 days."),
    h("دعوة للانضمام إلى عائلة في تطبيق أسرة") +
      p("أولًا، ثبّت تطبيق أسرة وأنشئ فيه حسابًا بالبريد الإلكتروني الذي وصلتك عليه هذه الدعوة.") +
      p("ثم افتح هذا الرابط مرة أخرى للانضمام إلى العائلة. الدعوة صالحة لمدة 7 أيام."),
  );

function invitePage(token: string, mfa: boolean, error?: InviteError): string {
  const copy = error ? INVITE_ERRORS[error] : undefined;
  const form = (en: boolean) => {
    const code = mfa
      ? `<label style="display:block">${en ? "Authenticator code" : "رمز تطبيق المصادقة"}<input name="mfaCode" required inputmode="numeric" pattern="[0-9 ]{6,7}" maxlength="7" autocomplete="one-time-code" style="${INPUT}"></label>`
      : "";
    return `<form method="post" action="/invite/accept">
      ${hidden(token)}
      <label style="display:block">${en ? "Password" : "كلمة المرور"}<input type="password" name="password" required maxlength="256" autocomplete="current-password" style="${INPUT}"></label>
      ${code}
      ${submit(en ? "Join the family" : "الانضمام إلى العائلة")}
    </form>`;
  };
  return page(
    h("You are invited to a family on OSRA") +
      err(copy?.en) +
      p("Enter your OSRA password to join the family.") +
      p("Your account moves to this family. If you set up a family of your own in OSRA, you will no longer see it.") +
      form(true),
    h("دعوة للانضمام إلى عائلة في تطبيق أسرة") +
      err(copy?.ar) +
      p("أدخل كلمة مرور حسابك في تطبيق أسرة للانضمام إلى العائلة.") +
      p("سينتقل حسابك إلى هذه العائلة. وإن كنت قد أنشأت عائلة خاصة بك في تطبيق أسرة، فلن تراها بعد ذلك.") +
      form(false),
  );
}

const inviteDonePage = () =>
  page(
    h("You have joined the family") + p("You have been signed out on every device. Open the OSRA app and sign in again to see the family."),
    h("انضممت إلى العائلة") + p("سُجّل خروجك من كل الأجهزة. افتح تطبيق أسرة وسجّل الدخول من جديد لترى العائلة."),
  );

/** Unknown, used, revoked, expired and malformed invitations, and one addressed to someone else. */
const inviteExpiredPage = () =>
  page(
    h("This invitation has expired or was already used") + p("Nothing was changed. Ask the person who invited you to send a new one."),
    h("انتهت صلاحية هذه الدعوة أو سبق استخدامها") + p("لم يتغيّر شيء. اطلب من الشخص الذي دعاك إرسال دعوة جديدة."),
  );

// --- Dashboard ---------------------------------------------------------------------------------------

const dashboardPage = () =>
  page(
    h("Open the OSRA app") + p("Your family's dashboard is in the OSRA app on your phone. Open the app to see it."),
    h("افتح تطبيق أسرة") + p("لوحة التحكم الخاصة بعائلتك موجودة في تطبيق أسرة على هاتفك. افتح التطبيق لتراها."),
  );

// -----------------------------------------------------------------------------------------------------

export async function linkPageRoutes(app: FastifyInstance) {
  // The forms post as application/x-www-form-urlencoded, which Fastify has no parser for. Registered
  // inside this plugin, so only these pages accept the type (as `routes/account.ts` does for its own).
  app.addContentTypeParser(
    "application/x-www-form-urlencoded",
    { parseAs: "string", bodyLimit: 8192 },
    (_req, body, done) => done(null, Object.fromEntries(new URLSearchParams(body as string))),
  );

  /**
   * Run the existing JSON route in-process. `remoteAddress` carries the caller's address as this request
   * resolved it (`req.ip`, already taken from `X-Forwarded-For` when a proxy is trusted), and the inner
   * request has no forwarding header of its own, so its `req.ip` is the person's either way and the auth
   * bucket there counts them, not 127.0.0.1 for everyone.
   */
  const call = async (req: FastifyRequest, url: string, payload: Record<string, string>) => {
    const res = await app.inject({
      method: "POST",
      url,
      payload,
      remoteAddress: req.ip,
    });
    let body: Record<string, unknown> = {};
    try {
      body = res.json() as Record<string, unknown>;
    } catch {
      /* a non-JSON answer is handled by its status alone */
    }
    return { status: res.statusCode, body };
  };

  /** Signed by this API, unexpired, and of the purpose this page is for. Reads nothing, spends nothing. */
  const signedFor = (token: string, purpose: string): boolean => {
    if (!JWT_PATTERN.test(token)) return false;
    try {
      return app.jwt.verify<{ purpose?: string }>(token).purpose === purpose;
    } catch {
      return false;
    }
  };

  // --- password reset ---

  app.get("/reset", async (req, reply) => {
    const token = queryToken(req);
    if (!signedFor(token, "password_reset")) return sendPage(reply, 404, resetExpiredPage());
    return sendPage(reply, 200, resetPage(token));
  });

  app.post("/reset", async (req, reply) => {
    const body = bodyOf(req);
    const token = str(body.token) ?? "";
    if (!signedFor(token, "password_reset")) return sendPage(reply, 404, resetExpiredPage());
    const password = str(body.password) ?? "";
    // Both checked before the JSON route is called. A mismatch is this page's own rule and must not
    // cost the parent their link; a short password the route would refuse as well (its 400 is mapped
    // below), and refusing it here spends none of the caller's auth bucket.
    if (password.length < MIN_PASSWORD) return sendPage(reply, 400, resetPage(token, RESET_ERRORS.too_short));
    if (password !== (str(body.passwordRepeat) ?? "")) return sendPage(reply, 400, resetPage(token, RESET_ERRORS.mismatch));

    const res = await call(req, "/v1/auth/reset/confirm", { token, password });
    if (res.status === 200) return sendPage(reply, 200, resetDonePage());
    if (res.status === 429) return sendPage(reply, 429, resetPage(token, RESET_ERRORS.too_many));
    // A 5xx there restores the link for a retry (#162), so the form comes back with the token in it.
    if (res.status >= 500) return sendPage(reply, 503, resetPage(token, RESET_ERRORS.unavailable));
    if (res.status === 400) return sendPage(reply, 400, resetPage(token, RESET_ERRORS.too_short));
    return sendPage(reply, 404, resetExpiredPage());
  });

  // --- MFA reset: the mailbox step ---

  app.get("/mfa/reset/confirm", async (req, reply) => {
    const token = queryToken(req);
    if (!signedFor(token, "mfa_reset_confirm")) return sendPage(reply, 404, mfaExpiredPage());
    return sendPage(reply, 200, mfaConfirmPage(token));
  });

  app.post("/mfa/reset/confirm", async (req, reply) => {
    const token = str(bodyOf(req).token) ?? "";
    if (!signedFor(token, "mfa_reset_confirm")) return sendPage(reply, 404, mfaExpiredPage());
    const res = await call(req, "/v1/auth/mfa/reset/confirm", { token });
    if (res.status === 200) return sendPage(reply, 200, mfaConfirmedPage(res.body.witness === "device" ? "device" : "parent"));
    if (res.status === 429) return sendPage(reply, 429, mfaConfirmPage(token, COMMON.too_many));
    if (res.status === 409) return sendPage(reply, 409, mfaNotOpenPage());
    // `reset_unavailable`: the store could not be reached and nothing was spent, so the button comes back.
    if (res.status >= 500 && res.body.error === "reset_unavailable") return sendPage(reply, 503, mfaConfirmPage(token, COMMON.unavailable));
    if (res.status >= 500) return sendPage(reply, 503, mfaFailedPage());
    return sendPage(reply, 404, mfaExpiredPage());
  });

  // --- MFA reset: the cancel link ---

  app.get("/mfa/reset/cancel", async (req, reply) => {
    const token = queryToken(req);
    if (!signedFor(token, "mfa_reset_cancel")) return sendPage(reply, 404, mfaExpiredPage());
    return sendPage(reply, 200, mfaCancelPage(token));
  });

  app.post("/mfa/reset/cancel", async (req, reply) => {
    const token = str(bodyOf(req).token) ?? "";
    if (!signedFor(token, "mfa_reset_cancel")) return sendPage(reply, 404, mfaExpiredPage());
    const res = await call(req, "/v1/auth/mfa/reset/cancel", { token });
    if (res.status === 200) {
      // The route is idempotent and answers with the state the request is in now. Only a cancelled
      // state may be reported as "cancelled": a reset that already completed was not stopped.
      const cancelled = typeof res.body.state === "string" && res.body.state.startsWith("cancelled");
      return sendPage(reply, 200, cancelled ? mfaCancelledPage() : mfaAlreadyClosedPage());
    }
    if (res.status === 429) return sendPage(reply, 429, mfaCancelPage(token, COMMON.too_many));
    if (res.status >= 500) return sendPage(reply, 503, mfaCancelPage(token, COMMON.unavailable));
    return sendPage(reply, 404, mfaExpiredPage());
  });

  // --- family invite ---

  /** The invitation and the account it is addressed to, read fresh on both the GET and the POST. */
  const inviteFor = async (token: string) => {
    if (!INVITE_PATTERN.test(token)) return null;
    const invite = await findOpenInvite(token);
    if (!invite) return null;
    return { parent: await prisma.parent.findUnique({ where: { email: invite.email.toLowerCase() } }) };
  };

  app.get("/invite/accept", async (req, reply) => {
    const token = queryToken(req);
    const found = await inviteFor(token);
    if (!found) return sendPage(reply, 404, inviteExpiredPage());
    if (!found.parent) return sendPage(reply, 200, inviteNoAccountPage());
    return sendPage(reply, 200, invitePage(token, found.parent.mfaEnabled));
  });

  /**
   * Join. No session exists on a web page, so the proof is the account's password, and the
   * authenticator code when MFA is on: `checkReauth`, the check the web deletion uses. Holding the
   * mail alone moves nobody. A wrong password leaves the invitation usable, and the route's own auth
   * rate limit (fails closed) makes the form no faster a password oracle than `/login`.
   */
  app.post("/invite/accept", { config: { rateLimit: AUTH_RATE_LIMIT } }, async (req, reply) => {
    const body = bodyOf(req);
    const token = str(body.token) ?? "";
    const found = await inviteFor(token);
    if (!found) return sendPage(reply, 404, inviteExpiredPage());
    const parent = found.parent;
    if (!parent) return sendPage(reply, 200, inviteNoAccountPage());

    // A browser sends an empty field for an unused input, and people type a code as "123 456".
    const mfaCode = str(body.mfaCode)?.replace(/\s+/g, "") || undefined;
    const reauth = ReauthSchema.safeParse({ password: str(body.password) ?? "", mfaCode });
    if (!reauth.success) {
      const error: InviteError = reauth.error.issues.some((i) => i.path[0] === "password") ? "password_required" : "reauth_failed";
      return sendPage(reply, 400, invitePage(token, parent.mfaEnabled, error));
    }
    const refusal = await checkReauth(parent, reauth.data);
    if (refusal) return sendPage(reply, 401, invitePage(token, parent.mfaEnabled, refusal));

    const result = await acceptInvite(token, parent);
    if (!result.ok) return sendPage(reply, 404, inviteExpiredPage());
    return sendPage(reply, 200, inviteDonePage());
  });

  // --- dashboard ---

  app.get("/dashboard", async (_req, reply) => sendPage(reply, 200, dashboardPage()));
}
