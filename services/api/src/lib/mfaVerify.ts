import { timingSafeEqual } from "node:crypto";
import { getRedis } from "../redis.js";
import { decryptSecret } from "./secretVault.js";
import { totpAtCounter } from "./totp.js";

// Moved from routes/auth.ts unchanged (#442): account deletion re-authenticates with the same check
// as sign-in, so a code accepted for one is spent for the other.

/**
 * Verify a login TOTP code with replay protection (review 3.1): the accepted
 * time-step counter is stored per parent, so a captured code cannot be reused
 * within its validity window.
 */
export async function verifyTotpFresh(parentId: string, storedSecret: string | null, code: string): Promise<boolean> {
  const secret = decryptSecret(storedSecret);
  if (!secret) return false;
  const now = Math.floor(Date.now() / 1000 / 30);
  let matched: number | null = null;
  for (const counter of [now - 1, now, now + 1]) {
    if (timingSafeEq(totpAtCounter(secret, counter), code)) { matched = counter; break; }
  }
  if (matched === null) return false;
  const redis = getRedis();
  const key = `mfa:lastcounter:${parentId}`;
  // Handoff item 7: replay protection must fail CLOSED in production. When Redis is
  // unreachable there, reject the code loudly instead of silently disabling the check.
  const production = process.env.NODE_ENV === "production";
  try {
    const last = await redis.get(key);
    if (last !== null && Number(last) >= matched) return false;
    await redis.set(key, String(matched));
    return true;
  } catch (err) {
    if (production) {
      console.error(`[security] MFA replay store unreachable for ${parentId} — rejecting login`, err);
      return false;
    }
    console.warn("[security] MFA replay store unreachable; replay protection disabled (dev only)", err);
    return true;
  }
}

/** Constant-time comparison of two equal-length digit strings. */
function timingSafeEq(a: string, b: string): boolean {
  const ba = Buffer.from(a.padStart(6, "0"));
  const bb = Buffer.from(b.padStart(6, "0"));
  return ba.length === bb.length && timingSafeEqual(ba, bb);
}
