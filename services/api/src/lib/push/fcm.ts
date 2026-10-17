import { createSign } from "node:crypto";
import { readFileSync } from "node:fs";
import type { FetchLike, PushMessage, PushProvider, PushResult } from "./types.js";

/**
 * Firebase Cloud Messaging, HTTP v1 API, authenticated with a service-account key — no SDK.
 *
 * Credentials come from `FCM_SERVICE_ACCOUNT_JSON` (the JSON, or its base64) or
 * `FCM_SERVICE_ACCOUNT_FILE`. The OAuth2 access token is minted by signing an RS256 JWT with the
 * service-account private key and exchanging it at Google's token endpoint; it is cached until
 * one minute before expiry. The legacy server-key API is not used (deprecated by Google).
 */

export interface ServiceAccount {
  project_id: string;
  client_email: string;
  private_key: string;
  token_uri?: string;
}

const SCOPE = "https://www.googleapis.com/auth/firebase.messaging";

function b64url(input: Buffer | string): string {
  return Buffer.from(input).toString("base64").replace(/=/g, "").replace(/\+/g, "-").replace(/\//g, "_");
}

/** Build and sign the OAuth2 JWT-bearer assertion. Exported for tests. */
export function buildAssertion(sa: ServiceAccount, nowSeconds: number): string {
  const header = b64url(JSON.stringify({ alg: "RS256", typ: "JWT" }));
  const claims = b64url(
    JSON.stringify({
      iss: sa.client_email,
      scope: SCOPE,
      aud: sa.token_uri ?? "https://oauth2.googleapis.com/token",
      iat: nowSeconds,
      exp: nowSeconds + 3600,
    }),
  );
  const signer = createSign("RSA-SHA256");
  signer.update(`${header}.${claims}`);
  const signature = b64url(signer.sign(sa.private_key));
  return `${header}.${claims}.${signature}`;
}

/** Parse the service account from env; returns null when push is not configured. */
export function loadServiceAccountFromEnv(env: NodeJS.ProcessEnv = process.env): ServiceAccount | null {
  const inline = env.FCM_SERVICE_ACCOUNT_JSON;
  const file = env.FCM_SERVICE_ACCOUNT_FILE;
  let raw: string | undefined;
  if (inline) {
    raw = inline.trim().startsWith("{") ? inline : Buffer.from(inline, "base64").toString("utf8");
  } else if (file) {
    raw = readFileSync(file, "utf8");
  }
  if (!raw) return null;
  const parsed = JSON.parse(raw) as Partial<ServiceAccount>;
  if (!parsed.project_id || !parsed.client_email || !parsed.private_key) {
    throw new Error("FCM service account is missing project_id, client_email or private_key");
  }
  return parsed as ServiceAccount;
}

export class FcmProvider implements PushProvider {
  readonly platform = "android" as const;
  private accessToken: { value: string; expiresAt: number } | null = null;

  constructor(
    private readonly sa: ServiceAccount,
    private readonly fetchImpl: FetchLike = fetch,
    private readonly now: () => number = () => Date.now(),
  ) {}

  private async token(): Promise<string> {
    const nowMs = this.now();
    if (this.accessToken && this.accessToken.expiresAt - 60_000 > nowMs) return this.accessToken.value;
    const assertion = buildAssertion(this.sa, Math.floor(nowMs / 1000));
    const res = await this.fetchImpl(this.sa.token_uri ?? "https://oauth2.googleapis.com/token", {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({
        grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
        assertion,
      }).toString(),
    });
    if (!res.ok) throw new Error(`FCM oauth token exchange failed: HTTP ${res.status}`);
    const json = (await res.json()) as { access_token: string; expires_in: number };
    this.accessToken = { value: json.access_token, expiresAt: nowMs + json.expires_in * 1000 };
    return json.access_token;
  }

  /** The FCM v1 message body for one token. Exported shape so tests can assert it. */
  static buildMessage(token: string, message: PushMessage) {
    return {
      message: {
        token,
        notification: { title: message.title, body: message.body },
        data: message.data,
        android: {
          priority: message.priority === "high" ? "HIGH" : "NORMAL",
          ...(message.threadId ? { collapse_key: message.threadId } : {}),
          notification: { channel_id: "osra_alerts", ...(message.threadId ? { tag: message.threadId } : {}) },
        },
        // Flutter parent app on iOS registers through FCM too; keep APNs headers coherent.
        apns: {
          headers: { "apns-priority": message.priority === "high" ? "10" : "5" },
          payload: { aps: { sound: "default", ...(message.threadId ? { "thread-id": message.threadId } : {}) } },
        },
      },
    };
  }

  async send(token: string, message: PushMessage): Promise<PushResult> {
    let bearer: string;
    try {
      bearer = await this.token();
    } catch (err) {
      return { ok: false, invalidToken: false, reason: (err as Error).message };
    }
    const res = await this.fetchImpl(
      `https://fcm.googleapis.com/v1/projects/${this.sa.project_id}/messages:send`,
      {
        method: "POST",
        headers: { authorization: `Bearer ${bearer}`, "content-type": "application/json" },
        body: JSON.stringify(FcmProvider.buildMessage(token, message)),
      },
    );
    if (res.ok) return { ok: true };
    let detail = "";
    try {
      const body = (await res.json()) as { error?: { status?: string; details?: Array<{ errorCode?: string }> } };
      detail = body.error?.details?.find((d) => d.errorCode)?.errorCode ?? body.error?.status ?? "";
    } catch {
      /* non-JSON error body */
    }
    // 404 + UNREGISTERED is the documented "token no longer valid" signal; 400 INVALID_ARGUMENT on
    // the token field means it was never valid. Both are grounds for pruning.
    const dead = res.status === 404 || detail === "UNREGISTERED" || detail === "INVALID_ARGUMENT";
    return { ok: false, invalidToken: dead, reason: `HTTP ${res.status} ${detail}`.trim() };
  }
}
