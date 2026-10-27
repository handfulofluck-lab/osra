import { createHash, randomBytes, randomUUID, timingSafeEqual } from "node:crypto";
import { getRedis } from "../redis.js";

/**
 * The parent approves each new device (plan 2.7, osra-security#3 PR 2).
 *
 * A pairing code no longer buys a device token by itself. `POST /pair/claim` records a **pending claim**
 * and answers with a claim id and a poll secret that only the claiming phone holds. The parent's pairing
 * screen (already open, showing the code) lists the claim and the parent taps Allow or Deny. The phone's
 * next poll then gets the device token, created at that moment, never earlier: no device token or HMAC
 * secret is ever stored in Redis.
 *
 * Keys, all bounded by the code's own 600 s life:
 * - `pair:<code>` → `{ childId, familyId }` (written by `POST /pair`, unchanged);
 * - `pair:<code>:claim` → the claim id. Written with SET NX, so a code has at most one claim;
 * - `pairclaim:<claimId>` → the {@link ClaimRecord}.
 *
 * The test server runs Redis 5.0 (no GETDEL, no KEEPTTL), so the atomic steps are Lua scripts. The tests
 * emulate each one by name ({@link PAIR_SCRIPTS}).
 */

export type ClaimStatus = "pending" | "approved" | "denied" | "paired";

export interface ClaimRecord {
  claimId: string;
  code: string;
  childId: string;
  familyId: string;
  status: ClaimStatus;
  platform: string;
  model: string;
  osVersion: string;
  deviceName?: string;
  pushToken?: string;
  /** sha256 of the poll secret; the secret itself is only ever in the claiming phone. */
  pollSecretHash: string;
  /** The parent who tapped Allow or Deny. */
  decidedBy?: string;
  /** Set once the poll has created the device (`status: "paired"`). */
  deviceId?: string;
}

/** How long a finished claim stays readable, so the parent's screen can show "paired" or "denied". */
export const CLAIM_RESULT_TTL_MS = 120_000;

export const PAIR_SCRIPTS = {
  /**
   * KEYS: `pair:<code>`, `pair:<code>:claim`. ARGV: claim id.
   * → `{0}` no such code · `{2}` the code already has a claim · `{1, payload, pttl}` reserved.
   */
  reserve:
    "local v = redis.call('GET', KEYS[1]); if not v then return {0} end; " +
    "local t = redis.call('PTTL', KEYS[1]); if t <= 0 then return {0} end; " +
    "if not redis.call('SET', KEYS[2], ARGV[1], 'NX', 'PX', t) then return {2} end; " +
    "return {1, v, t}",
  /** KEYS: one key. ARGV: expected value, new value. Replaces it, keeping its TTL, only if unchanged → 1/0. */
  compareAndSet:
    "if redis.call('GET', KEYS[1]) ~= ARGV[1] then return 0 end; " +
    "local t = redis.call('PTTL', KEYS[1]); if t <= 0 then return 0 end; " +
    "redis.call('SET', KEYS[1], ARGV[2], 'PX', t); return 1",
  /** KEYS: one key. ARGV: expected value. Deletes it only if unchanged → 1/0. One poll wins. */
  compareAndDelete:
    "if redis.call('GET', KEYS[1]) ~= ARGV[1] then return 0 end; redis.call('DEL', KEYS[1]); return 1",
} as const;

const codeKey = (code: string) => `pair:${code}`;
const codeClaimKey = (code: string) => `pair:${code}:claim`;
const claimKey = (claimId: string) => `pairclaim:${claimId}`;

export function hashPollSecret(secret: string): string {
  return createHash("sha256").update(secret).digest("hex");
}

/** Constant-time comparison of a submitted poll secret with the stored hash. */
export function pollSecretMatches(secret: string, storedHash: string): boolean {
  const a = Buffer.from(hashPollSecret(secret), "hex");
  const b = Buffer.from(storedHash, "hex");
  return a.length === b.length && timingSafeEqual(a, b);
}

export type ReserveResult =
  | { kind: "unknown" }
  | { kind: "pending_exists" }
  | { kind: "reserved"; claimId: string; pollSecret: string; expiresAt: string; record: ClaimRecord };

/**
 * Turn a code into a pending claim. The code itself is not consumed: it stays until the parent decides,
 * it expires, or the device is created. The SET NX on `pair:<code>:claim` makes a second claim on the same
 * code fail while the first one is pending.
 */
export async function reserveClaim(
  code: string,
  device: Pick<ClaimRecord, "platform" | "model" | "osVersion" | "deviceName" | "pushToken">,
): Promise<ReserveResult> {
  const claimId = randomUUID();
  const res = (await getRedis().eval(PAIR_SCRIPTS.reserve, 2, codeKey(code), codeClaimKey(code), claimId)) as
    | [number, string?, number?]
    | null;
  if (!res || res[0] === 0) return { kind: "unknown" };
  if (res[0] === 2) return { kind: "pending_exists" };
  const payload = JSON.parse(String(res[1])) as { childId: string; familyId: string };
  const ttlMs = Number(res[2]);
  const pollSecret = randomBytes(32).toString("base64url");
  const record: ClaimRecord = {
    claimId,
    code,
    childId: payload.childId,
    familyId: payload.familyId,
    status: "pending",
    ...device,
    pollSecretHash: hashPollSecret(pollSecret),
  };
  await getRedis().set(claimKey(claimId), JSON.stringify(record), "PX", ttlMs);
  return { kind: "reserved", claimId, pollSecret, expiresAt: new Date(Date.now() + ttlMs).toISOString(), record };
}

/** The stored record and its exact serialisation, for a compare-and-set. */
export async function readClaim(claimId: string): Promise<{ record: ClaimRecord; raw: string } | null> {
  const raw = await getRedis().get(claimKey(claimId));
  return raw ? { record: JSON.parse(raw) as ClaimRecord, raw } : null;
}

/** The claim on a code, if one was made: what the parent's pairing screen polls. */
export async function readClaimForCode(code: string): Promise<{ codeLive: boolean; familyId: string | null; claim: ClaimRecord | null }> {
  const redis = getRedis();
  const [payloadRaw, claimId] = await Promise.all([redis.get(codeKey(code)), redis.get(codeClaimKey(code))]);
  const payload = payloadRaw ? (JSON.parse(payloadRaw) as { familyId: string }) : null;
  const claim = claimId ? (await readClaim(claimId))?.record ?? null : null;
  return { codeLive: payload !== null, familyId: payload?.familyId ?? claim?.familyId ?? null, claim };
}

/**
 * Allow or Deny a pending claim. Only a `pending` claim changes; a second decision, or one racing the
 * claim's expiry, gets `false`. Deny also deletes the code, so the parent makes a new one.
 */
export async function decideClaim(current: { record: ClaimRecord; raw: string }, decision: "approved" | "denied", parentId: string): Promise<boolean> {
  if (current.record.status !== "pending") return false;
  const next: ClaimRecord = { ...current.record, status: decision, decidedBy: parentId };
  const ok = (await getRedis().eval(PAIR_SCRIPTS.compareAndSet, 1, claimKey(current.record.claimId), current.raw, JSON.stringify(next))) === 1;
  if (ok && decision === "denied") await getRedis().del(codeKey(current.record.code));
  return ok;
}

/**
 * The poll that finds the claim approved takes it, atomically, so exactly one poll creates the device.
 * The caller creates the device and then calls {@link markPaired}.
 */
export async function takeApprovedClaim(current: { record: ClaimRecord; raw: string }): Promise<boolean> {
  if (current.record.status !== "approved") return false;
  return (await getRedis().eval(PAIR_SCRIPTS.compareAndDelete, 1, claimKey(current.record.claimId), current.raw)) === 1;
}

/** After the device exists: burn the code, and keep a short "paired" record for the parent's screen. */
export async function markPaired(record: ClaimRecord, deviceId: string): Promise<void> {
  const redis = getRedis();
  await redis.del(codeKey(record.code));
  const done: ClaimRecord = { ...record, status: "paired", deviceId };
  await redis.set(claimKey(record.claimId), JSON.stringify(done), "PX", CLAIM_RESULT_TTL_MS);
  await redis.set(codeClaimKey(record.code), record.claimId, "PX", CLAIM_RESULT_TTL_MS);
}
