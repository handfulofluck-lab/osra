/**
 * Outbound email (Phase 2a). One interface, two senders:
 *  - `ResendEmailSender` — HTTPS API (`RESEND_API_KEY`, `EMAIL_FROM`), no SDK;
 *  - `ConsoleEmailSender` — development/test fallback that logs the envelope. It never logs the
 *    body in production, so a misconfigured deploy cannot leak reset links into log aggregation.
 *
 * Callers never embed secrets in the body beyond the single-use link they are sending; templates
 * live in `templates.ts` so copy and HTML stay out of route handlers.
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
  const key = env.RESEND_API_KEY;
  const from = env.EMAIL_FROM;
  if (key && from) sender = new ResendEmailSender(key, from);
  else {
    if (key && !from) console.warn("[email] RESEND_API_KEY set but EMAIL_FROM missing; email disabled");
    sender = new ConsoleEmailSender();
  }
  return sender;
}

/** True when a real provider is configured — routes use it to decide whether a token may be echoed in dev. */
export function emailConfigured(env: NodeJS.ProcessEnv = process.env): boolean {
  return Boolean(env.RESEND_API_KEY && env.EMAIL_FROM);
}

/** Public base URL of the parent-facing app, used to build links in emails. */
export function appPublicUrl(env: NodeJS.ProcessEnv = process.env): string {
  return (env.APP_PUBLIC_URL ?? "http://localhost:3000").replace(/\/+$/, "");
}
