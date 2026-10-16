import { createSign } from "node:crypto";
import { connect, type ClientHttp2Session } from "node:http2";
import type { PushMessage, PushProvider, PushResult } from "./types.js";

/**
 * Apple Push Notification service over HTTP/2 with token-based (p8) authentication — no SDK.
 *
 * Env: `APNS_KEY_P8` (PEM, or its base64), `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_BUNDLE_ID`,
 * `APNS_ENV` = "production" | "sandbox" (default sandbox outside production). The provider JWT is
 * ES256 and is reused for 50 minutes (Apple accepts up to 60). One HTTP/2 session is kept open and
 * re-dialled on error.
 *
 * Used when the parent app is a native iOS build registering directly with APNs. The Flutter parent
 * app registers through FCM on both platforms, so in the current product this provider is a
 * ready path rather than the default one; `notify.ts` routes by the token's `platform`.
 */

export interface ApnsConfig {
  keyP8: string;
  keyId: string;
  teamId: string;
  bundleId: string;
  host: string;
}

function b64url(input: Buffer | string): string {
  return Buffer.from(input).toString("base64").replace(/=/g, "").replace(/\+/g, "-").replace(/\//g, "_");
}

/** DER ECDSA signature → raw r||s (64 bytes) as JOSE requires for ES256. */
function derToJose(der: Buffer): Buffer {
  let offset = 2; // 0x30 len
  if (der[1] & 0x80) offset += der[1] & 0x7f;
  const readInt = (): Buffer => {
    if (der[offset++] !== 0x02) throw new Error("bad DER");
    let len = der[offset++];
    if (len & 0x80) {
      const n = len & 0x7f;
      len = 0;
      for (let i = 0; i < n; i++) len = (len << 8) | der[offset++];
    }
    let v = der.subarray(offset, offset + len);
    offset += len;
    while (v.length > 32 && v[0] === 0) v = v.subarray(1);
    return Buffer.concat([Buffer.alloc(32 - v.length), v]);
  };
  const r = readInt();
  const s = readInt();
  return Buffer.concat([r, s]);
}

/** Build the ES256 provider token. Exported for tests. */
export function buildProviderToken(cfg: Pick<ApnsConfig, "keyP8" | "keyId" | "teamId">, nowSeconds: number): string {
  const header = b64url(JSON.stringify({ alg: "ES256", kid: cfg.keyId }));
  const claims = b64url(JSON.stringify({ iss: cfg.teamId, iat: nowSeconds }));
  const signer = createSign("SHA256");
  signer.update(`${header}.${claims}`);
  const der = signer.sign(cfg.keyP8);
  return `${header}.${claims}.${b64url(derToJose(der))}`;
}

export function loadApnsConfigFromEnv(env: NodeJS.ProcessEnv = process.env): ApnsConfig | null {
  const { APNS_KEY_P8, APNS_KEY_ID, APNS_TEAM_ID, APNS_BUNDLE_ID } = env;
  if (!APNS_KEY_P8 || !APNS_KEY_ID || !APNS_TEAM_ID || !APNS_BUNDLE_ID) return null;
  const keyP8 = APNS_KEY_P8.includes("BEGIN") ? APNS_KEY_P8 : Buffer.from(APNS_KEY_P8, "base64").toString("utf8");
  const production = (env.APNS_ENV ?? (env.NODE_ENV === "production" ? "production" : "sandbox")) === "production";
  return {
    keyP8,
    keyId: APNS_KEY_ID,
    teamId: APNS_TEAM_ID,
    bundleId: APNS_BUNDLE_ID,
    host: production ? "https://api.push.apple.com" : "https://api.sandbox.push.apple.com",
  };
}

/** Transport seam so the HTTP/2 path can be replaced in tests. */
export type ApnsTransport = (
  host: string,
  path: string,
  headers: Record<string, string>,
  body: string,
) => Promise<{ status: number; body: string }>;

export function http2Transport(): ApnsTransport {
  let session: ClientHttp2Session | null = null;
  const getSession = (host: string): ClientHttp2Session => {
    if (session && !session.closed && !session.destroyed) return session;
    session = connect(host);
    session.on("error", () => {
      session?.destroy();
      session = null;
    });
    return session;
  };
  return (host, path, headers, body) =>
    new Promise((resolve, reject) => {
      const req = getSession(host).request({ ":method": "POST", ":path": path, ...headers });
      let status = 0;
      const chunks: Buffer[] = [];
      req.on("response", (h) => {
        status = Number(h[":status"] ?? 0);
      });
      req.on("data", (c: Buffer) => chunks.push(c));
      req.on("end", () => resolve({ status, body: Buffer.concat(chunks).toString("utf8") }));
      req.on("error", reject);
      req.end(body);
    });
}

export class ApnsProvider implements PushProvider {
  readonly platform = "ios" as const;
  private jwt: { value: string; issuedAt: number } | null = null;

  constructor(
    private readonly cfg: ApnsConfig,
    private readonly transport: ApnsTransport = http2Transport(),
    private readonly now: () => number = () => Date.now(),
  ) {}

  private providerToken(): string {
    const nowMs = this.now();
    if (this.jwt && nowMs - this.jwt.issuedAt < 50 * 60_000) return this.jwt.value;
    this.jwt = { value: buildProviderToken(this.cfg, Math.floor(nowMs / 1000)), issuedAt: nowMs };
    return this.jwt.value;
  }

  static buildPayload(message: PushMessage) {
    return {
      aps: {
        alert: { title: message.title, body: message.body },
        sound: message.priority === "high" ? "default" : undefined,
        ...(message.threadId ? { "thread-id": message.threadId } : {}),
        "mutable-content": 1,
      },
      ...message.data,
    };
  }

  async send(token: string, message: PushMessage): Promise<PushResult> {
    const headers = {
      authorization: `bearer ${this.providerToken()}`,
      "apns-topic": this.cfg.bundleId,
      "apns-push-type": "alert",
      "apns-priority": message.priority === "high" ? "10" : "5",
      ...(message.threadId ? { "apns-collapse-id": message.threadId.slice(0, 64) } : {}),
    };
    let res: { status: number; body: string };
    try {
      res = await this.transport(this.cfg.host, `/3/device/${token}`, headers, JSON.stringify(ApnsProvider.buildPayload(message)));
    } catch (err) {
      return { ok: false, invalidToken: false, reason: (err as Error).message };
    }
    if (res.status === 200) return { ok: true };
    let reason = "";
    try {
      reason = (JSON.parse(res.body) as { reason?: string }).reason ?? "";
    } catch {
      /* empty body */
    }
    const dead = res.status === 410 || reason === "BadDeviceToken" || reason === "Unregistered" || reason === "DeviceTokenNotForTopic";
    return { ok: false, invalidToken: dead, reason: `HTTP ${res.status} ${reason}`.trim() };
  }
}
