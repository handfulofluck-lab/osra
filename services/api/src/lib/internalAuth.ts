import { createHmac, timingSafeEqual } from "node:crypto";
import type { FastifyInstance } from "fastify";
import { prisma } from "../db.js";
import { getRedis } from "../redis.js";

/**
 * Internal request signing — `X-FamilyShield-Signature` (ADR-0014, Phase 2d).
 *
 * v2 (the contract from this release on):
 *   X-FamilyShield-Timestamp: <unix seconds>
 *   X-FamilyShield-Nonce:     <16..128 chars, unique per request>
 *   X-FamilyShield-Signature: hex HMAC-SHA256(secret, `${timestamp}.${nonce}.${rawBody}`)
 * A request older or newer than `SIGNATURE_MAX_SKEW_SECONDS` (300) is rejected (`stale_timestamp`);
 * a nonce seen before for the same signer within the nonce window is rejected (`replay`). That is
 * what closes probe target J2: a byte-identical request cannot be accepted twice.
 *
 * v1 (body-only signature, no timestamp header) is the format the shipped agents used. It is
 * accepted for per-device secrets only while `INTERNAL_SIGNING_ALLOW_V1` is not `0` — the switch
 * exists so a fleet can update agent by agent; set it to `0` once every agent signs v2. The global
 * secret is never accepted in v1.
 *
 * Who may sign with what (handoff item 5 + target J6):
 *   - A body that names a device (`deviceId`, or `X-Device-Id`) must be signed with THAT device's
 *     per-device secret; a device without a secret cannot be acted on by a body-only signer
 *     (J6 — the fallback that let the bare global secret write into a secret-less device is closed).
 *   - A body that names only a child may be signed by any of that child's devices' secrets.
 *   - The global `INTERNAL_HMAC_SECRET` is a SERVICE credential: accepted only in v2 and only with
 *     `X-FamilyShield-Caller` naming a known service (`INTERNAL_SERVICE_CALLERS`, default
 *     `ai-engine`). Without that header it authenticates nothing, so it can never stand in for a
 *     device (J5). With it, the service may name a child or a device in its body.
 */
export interface InternalAuthResult {
  valid: boolean;
  /** Set when `valid` is false: a stable code for the 401 body and the logs. */
  reason?: "missing_signature" | "invalid_signature" | "stale_timestamp" | "missing_nonce" | "replay" | "legacy_signature_disabled" | "global_secret_requires_service_caller" | "device_has_no_secret";
  version?: 1 | 2;
  device?: {
    id: string;
    childId: string;
    internalSecret?: string | null;
    revokedAt?: Date | null;
  } | null;
  isGlobalSecret?: boolean;
  caller?: string;
}

export const SIGNATURE_MAX_SKEW_SECONDS = 300;
const NONCE_TTL_SECONDS = 2 * SIGNATURE_MAX_SKEW_SECONDS;
const NONCE_RE = /^[A-Za-z0-9._:-]{16,128}$/;

export const HEADER_SIGNATURE = "x-familyshield-signature";
export const HEADER_TIMESTAMP = "x-familyshield-timestamp";
export const HEADER_NONCE = "x-familyshield-nonce";
export const HEADER_CALLER = "x-familyshield-caller";
export const HEADER_DEVICE_ID = "x-device-id";

export function allowLegacyV1(env: NodeJS.ProcessEnv = process.env): boolean {
  return env.INTERNAL_SIGNING_ALLOW_V1 !== "0";
}

export function serviceCallers(env: NodeJS.ProcessEnv = process.env): Set<string> {
  return new Set((env.INTERNAL_SERVICE_CALLERS ?? "ai-engine").split(",").map((s) => s.trim()).filter(Boolean));
}

/** The string a v2 signer MACs: timestamp, nonce and the raw body, dot-joined. */
export function signingStringV2(timestamp: string, nonce: string, rawBody: string | Buffer): Buffer {
  return Buffer.concat([Buffer.from(`${timestamp}.${nonce}.`, "utf8"), Buffer.isBuffer(rawBody) ? rawBody : Buffer.from(rawBody, "utf8")]);
}

function hmacHex(secret: string, data: string | Buffer): string {
  return createHmac("sha256", secret).update(data).digest("hex");
}

function safeEq(a: string, b: string): boolean {
  const ba = Buffer.from(a, "utf8");
  const bb = Buffer.from(b, "utf8");
  return ba.length === bb.length && timingSafeEqual(ba, bb);
}

function one(h: string | string[] | undefined): string | undefined {
  return Array.isArray(h) ? h[0] : h;
}

/** Produce the three v2 headers for a request (used by tests, scripts and in-repo callers). */
export function signV2(secret: string, rawBody: string, opts: { timestamp?: number; nonce?: string; caller?: string } = {}): Record<string, string> {
  const ts = String(opts.timestamp ?? Math.floor(Date.now() / 1000));
  const nonce = opts.nonce ?? `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 14)}-${Math.random().toString(36).slice(2, 10)}`;
  return {
    [HEADER_SIGNATURE]: hmacHex(secret, signingStringV2(ts, nonce, rawBody)),
    [HEADER_TIMESTAMP]: ts,
    [HEADER_NONCE]: nonce,
    ...(opts.caller ? { [HEADER_CALLER]: opts.caller } : {}),
  };
}

type Envelope =
  | { version: 2; timestamp: string; nonce: string; sig: string }
  | { version: 1; sig: string };

function readEnvelope(headers: Record<string, string | string[] | undefined>, sig: string, now: number): { env?: Envelope; reason?: InternalAuthResult["reason"] } {
  const ts = one(headers[HEADER_TIMESTAMP]);
  const nonce = one(headers[HEADER_NONCE]);
  if (ts === undefined && nonce === undefined) return { env: { version: 1, sig } };
  if (!ts || !/^\d{9,11}$/.test(ts)) return { reason: "stale_timestamp" };
  if (Math.abs(now - Number(ts)) > SIGNATURE_MAX_SKEW_SECONDS) return { reason: "stale_timestamp" };
  if (!nonce || !NONCE_RE.test(nonce)) return { reason: "missing_nonce" };
  return { env: { version: 2, timestamp: ts, nonce, sig } };
}

function verifyWith(secret: string, rawBody: string | Buffer, env: Envelope): boolean {
  const data = env.version === 2 ? signingStringV2(env.timestamp, env.nonce, rawBody) : rawBody;
  return safeEq(env.sig, hmacHex(secret, data));
}

/** Claim a nonce for a signer; false when it was already used inside the window (replay). */
async function claimNonce(signerId: string, nonce: string): Promise<boolean> {
  const r = await getRedis().set(`nonce:${signerId}:${nonce}`, "1", "EX", NONCE_TTL_SECONDS, "NX").catch(() => "OK");
  return r === "OK";
}

/**
 * Authenticate an internal request. `rawBody` is the exact bytes the signer MAC'd (see
 * `registerRawBodyParser`), `headers` the request headers (lower-cased by Fastify).
 */
export async function authenticateInternalRequest(
  rawBody: string | Buffer | undefined,
  signature: string | string[] | undefined,
  headers: Record<string, string | string[] | undefined> = {},
  now: number = Math.floor(Date.now() / 1000),
  envVars: NodeJS.ProcessEnv = process.env,
): Promise<InternalAuthResult> {
  const sig = one(signature);
  if (!sig || rawBody === undefined) return { valid: false, reason: "missing_signature" };
  const { env, reason } = readEnvelope(headers, sig, now);
  if (!env) return { valid: false, reason };

  let parsed: { deviceId?: string; childId?: string } = {};
  try {
    parsed = JSON.parse(rawBody.toString()) as { deviceId?: string; childId?: string };
  } catch {
    parsed = {};
  }
  const deviceId = parsed.deviceId ?? one(headers[HEADER_DEVICE_ID]);

  // 1. The global secret is a SERVICE credential: v2 only, with a named, known caller. A service
  //    (the ai-engine) may name a child or a device in its body — it is not pretending to be the
  //    device, it is the trusted process that scores its traffic. Without the caller header the
  //    global secret authenticates nothing (J5/J6: it can never stand in for a device).
  const globalSecret = envVars.INTERNAL_HMAC_SECRET;
  if (globalSecret && verifyWith(globalSecret, rawBody, env)) {
    const caller = one(headers[HEADER_CALLER]);
    if (env.version !== 2 || !caller || !serviceCallers(envVars).has(caller)) {
      return { valid: false, reason: "global_secret_requires_service_caller" };
    }
    if (!(await claimNonce(`service:${caller}`, env.nonce))) return { valid: false, reason: "replay" };
    return { valid: true, version: 2, isGlobalSecret: true, caller };
  }

  // 2. A named device must sign with its own secret — nothing else is accepted for it, and a device
  //    without a secret cannot be acted on by a body-only signer (the old fallback is closed).
  if (deviceId) {
    const device = await prisma.device.findUnique({ where: { id: deviceId } });
    if (!device?.internalSecret) return { valid: false, reason: "device_has_no_secret" };
    if (!verifyWith(device.internalSecret, rawBody, env)) return { valid: false, reason: "invalid_signature" };
    if (env.version === 1 && !allowLegacyV1(envVars)) return { valid: false, reason: "legacy_signature_disabled" };
    if (env.version === 2 && !(await claimNonce(device.id, env.nonce))) return { valid: false, reason: "replay" };
    return { valid: true, version: env.version, device };
  }

  // 3. A child-only body may be signed by any of the child's devices.
  if (parsed.childId) {
    const childDevices = await prisma.device.findMany({ where: { childId: parsed.childId } });
    for (const dev of childDevices) {
      if (dev.internalSecret && verifyWith(dev.internalSecret, rawBody, env)) {
        if (env.version === 1 && !allowLegacyV1(envVars)) return { valid: false, reason: "legacy_signature_disabled" };
        if (env.version === 2 && !(await claimNonce(dev.id, env.nonce))) return { valid: false, reason: "replay" };
        return { valid: true, version: env.version, device: dev };
      }
    }
  }

  return { valid: false, reason: "invalid_signature" };
}

export async function verifyInternalSignature(
  rawBody: string | Buffer | undefined,
  signature: string | string[] | undefined,
  headers?: Record<string, string | string[] | undefined>,
): Promise<boolean> {
  const result = await authenticateInternalRequest(rawBody, signature, headers);
  return result.valid;
}

/** Register a JSON parser that keeps the raw body string for HMAC verification. */
export function registerRawBodyParser(app: FastifyInstance): void {
  app.addContentTypeParser("application/json", { parseAs: "string" }, (req, body, done) => {
    (req as { rawBody?: string }).rawBody = body as string;
    try {
      done(null, JSON.parse(body as string));
    } catch (err) {
      done(err as Error);
    }
  });
}
