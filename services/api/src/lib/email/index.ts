/**
 * Outbound email (Phase 2a). One interface, two senders:
 *  - `ResendEmailSender` — HTTPS API (`RESEND_API_KEY`, `EMAIL_FROM`), no SDK;
 *  - `ConsoleEmailSender` — development/test fallback that logs the envelope. It never logs the
 *    body in production, so a misconfigured deploy cannot leak reset links into log aggregation.
 *
 * Callers never embed secrets in the body beyond the single-use link they are sending; templates
 * live in `templates.ts` so copy and HTML stay out of route handlers.
 */

import { SESv2Client, SendEmailCommand, type SendEmailCommandInput } from "@aws-sdk/client-sesv2";

/**
 * Imported statically on purpose: this module is ESM (`"type": "module"`, `node dist/server.js`), so a
 * `require(...)` here throws `ReferenceError: require is not defined` at runtime in the container — while
 * `tsc` accepts it, because `@types/node` still declares `require`. Importing the SDK reads no credentials;
 * the provider chain resolves on the first `send`, which is why the *client* is what stays lazy.
 */
export interface EmailMessage {
  to: string | string[];
  subject: string;
  html: string;
  text: string;
  /** Idempotency key: the provider drops duplicates with the same key within its window. */
  idempotencyKey?: string;
}

export type EmailResult =
  | { ok: true; id?: string }
  /**
   * `retryable` is the sender's classification of the refusal, not a guess by the caller: a
   * transport/rate-limit/server failure may succeed on the next attempt, a 4xx (an address the
   * provider will never accept) may not. A `send` that *throws* is by definition unclassified and
   * callers treat it as transient.
   */
  | { ok: false; reason: string; retryable: boolean };

export interface EmailSender {
  readonly name: string;
  send(message: EmailMessage): Promise<EmailResult>;
}

type FetchLike = (input: string, init?: RequestInit) => Promise<Response>;

export class ResendEmailSender implements EmailSender {
  readonly name = "resend";
  constructor(
    private readonly apiKey: string,
    private readonly from: string,
    private readonly fetchImpl: FetchLike = fetch,
  ) {}

  async send(message: EmailMessage): Promise<EmailResult> {
    const res = await this.fetchImpl("https://api.resend.com/emails", {
      method: "POST",
      headers: {
        authorization: `Bearer ${this.apiKey}`,
        "content-type": "application/json",
        ...(message.idempotencyKey ? { "idempotency-key": message.idempotencyKey } : {}),
      },
      body: JSON.stringify({
        from: this.from,
        to: Array.isArray(message.to) ? message.to : [message.to],
        subject: message.subject,
        html: message.html,
        text: message.text,
      }),
    });
    if (res.ok) {
      const json = (await res.json().catch(() => ({}))) as { id?: string };
      return { ok: true, id: json.id };
    }
    const body = await res.text().catch(() => "");
    // 408 (timeout), 429 (rate limit) and 5xx are the provider's fault or the network's: retry.
    // Every other 4xx is about this message or this recipient — a retry sends the same bad request.
    const retryable = res.status === 408 || res.status === 429 || res.status >= 500;
    return { ok: false, reason: `HTTP ${res.status} ${body.slice(0, 200)}`, retryable };
  }
}

/**
 * AWS SES (v2) sender — Play decision 11 A, Karim 2026-11-11. Replaces Resend once it is the default.
 *
 * **No credentials in the environment.** On Fargate the task role supplies them through the default provider
 * chain, so there is no key to leak into a repo, a log or a `.env`. `EMAIL_FROM` stays the single source of
 * the From address, and the SES identity (DKIM) for that domain is infrastructure, not this file.
 *
 * The classification matches the Resend sender's, because callers branch on it: throttling, timeouts and 5xx
 * are the provider's fault and are retried; any other 4xx is about this message or this recipient and is not.
 */
export class SesEmailSender implements EmailSender {
  readonly name = "ses";
  /**
   * The transport is injected rather than the client, so a unit test asserts the exact request SES receives
   * and a network failure cannot reach the suite. `buildSesSender` is the only place that knows about
   * `SendEmailCommand`.
   */
  constructor(
    private readonly transport: (input: Record<string, unknown>) => Promise<{ MessageId?: string }>,
    private readonly from: string,
  ) {}

  async send(message: EmailMessage): Promise<EmailResult> {
    const to = Array.isArray(message.to) ? message.to : [message.to];
    try {
      const out = await this.transport({
        FromEmailAddress: this.from,
        Destination: { ToAddresses: to },
        Content: {
          Simple: {
            Subject: { Data: message.subject, Charset: "UTF-8" },
            Body: {
              Html: { Data: message.html, Charset: "UTF-8" },
              Text: { Data: message.text, Charset: "UTF-8" },
            },
          },
        },
      });
      return { ok: true, id: out.MessageId };
    } catch (err) {
      // SES errors carry `$metadata.httpStatusCode`; a network failure has none and is transient.
      const e = err as { name?: string; message?: string; $metadata?: { httpStatusCode?: number } };
      const status = e.$metadata?.httpStatusCode;
      const retryable =
        status === undefined ||
        status === 408 ||
        status === 429 ||
        status >= 500 ||
        e.name === "ThrottlingException" ||
        e.name === "TooManyRequestsException";
      return { ok: false, reason: `${e.name ?? "error"}: ${(e.message ?? "").slice(0, 200)}`, retryable };
    }
  }
}

export class ConsoleEmailSender implements EmailSender {
  readonly name = "console";
  constructor(private readonly production = process.env.NODE_ENV === "production") {}
  async send(message: EmailMessage): Promise<EmailResult> {
    const to = Array.isArray(message.to) ? message.to.join(",") : message.to;
    if (this.production) {
      console.warn(`[email:unconfigured] would send "${message.subject}" to ${to} — set RESEND_API_KEY`);
    } else {
      console.log(`[email:dev] to=${to} subject="${message.subject}"\n${message.text}`);
    }
    return { ok: true };
  }
}

let sender: EmailSender | null = null;

export function setEmailSender(s: EmailSender | null): void {
  sender = s;
}

export function getEmailSender(env: NodeJS.ProcessEnv = process.env): EmailSender {
  if (sender) return sender;
  const from = env.EMAIL_FROM;
  const provider = (env.EMAIL_PROVIDER ?? "").trim().toLowerCase();
  if (provider === "ses" && from) {
    // The client is constructed lazily, so importing this module never needs AWS credentials.
    sender = buildSesSender(from, env);
    return sender;
  }
  if (provider === "ses" && !from) console.warn("[email] EMAIL_PROVIDER=ses but EMAIL_FROM missing; email disabled");
  const key = env.RESEND_API_KEY;
  if (key && from) sender = new ResendEmailSender(key, from);
  else {
    if (key && !from) console.warn("[email] RESEND_API_KEY set but EMAIL_FROM missing; email disabled");
    sender = new ConsoleEmailSender();
  }
  return sender;
}

/**
 * The real client, built here so `@aws-sdk/client-sesv2` is only loaded when SES is selected. On Fargate the
 * task role is the credential source; nothing is read from env.
 */
function buildSesSender(from: string, env: NodeJS.ProcessEnv = process.env): EmailSender {
  const client = new SESv2Client(env.AWS_REGION ? { region: env.AWS_REGION } : {});
  return new SesEmailSender(
    (input) => client.send(new SendEmailCommand(input as unknown as SendEmailCommandInput)),
    from,
  );
}

/** True when a real provider is configured — routes use it to decide whether a token may be echoed in dev. */
export function emailConfigured(env: NodeJS.ProcessEnv = process.env): boolean {
  const provider = (env.EMAIL_PROVIDER ?? "").trim().toLowerCase();
  if (provider === "ses") return Boolean(env.EMAIL_FROM);
  return Boolean(env.RESEND_API_KEY && env.EMAIL_FROM);
}

/** Public base URL of the parent-facing app, used to build links in emails. */
export function appPublicUrl(env: NodeJS.ProcessEnv = process.env): string {
  return (env.APP_PUBLIC_URL ?? "http://localhost:3000").replace(/\/+$/, "");
}
