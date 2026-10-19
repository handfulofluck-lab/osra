import { createHash, randomBytes } from "node:crypto";

/**
 * One-time MFA recovery codes (ADR-0023 Option A).
 *
 * Format: 16 Crockford base32 characters = 80 bits, displayed `XXXX-XXXX-XXXX-XXXX`. The alphabet
 * drops `I`, `L`, `O` and `U`, so a code survives being read aloud or copied by hand.
 *
 * Storage: SHA-256 of the normalised code, never the plaintext. The value is uniformly random, so
 * there is nothing to stretch — argon2 would only add latency to a lookup that is already bounded by
 * the auth rate limit. 80 bits keeps an offline guess infeasible even if the table leaks.
 */

/** Crockford base32: no I, L, O, U. */
const ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";

export const RECOVERY_CODE_COUNT = 10;
export const RECOVERY_CODE_LENGTH = 16;
export const RECOVERY_CODE_TTL_MINUTES = 15;

/** One code: 10 random bytes = 80 bits, encoded five bits at a time (exactly 16 characters). */
export function generateRecoveryCode(): string {
  let bits = 0;
  let value = 0;
  let out = "";
  for (const byte of randomBytes(10)) {
    value = (value << 8) | byte;
    bits += 8;
    while (bits >= 5) {
      out += ALPHABET[(value >>> (bits - 5)) & 31];
      bits -= 5;
    }
    value &= (1 << bits) - 1;
  }
  return out;
}

/** A fresh batch, distinct by construction (a collision would silently shrink the batch). */
export function generateRecoveryCodeBatch(count = RECOVERY_CODE_COUNT): string[] {
  const codes = new Set<string>();
  while (codes.size < count) codes.add(generateRecoveryCode());
  return [...codes];
}

/** `XXXX-XXXX-XXXX-XXXX`, the form the parent is shown. */
export function formatRecoveryCode(code: string): string {
  return code.replace(/-/g, "").match(/.{1,4}/g)?.join("-") ?? code;
}

/**
 * Uppercase, drop separators, and map the characters a human confuses when retyping a Crockford
 * code (`I`/`L` read as `1`, `O` as `0`). The generator never emits those four letters, so mapping
 * them cannot change the meaning of a code we issued.
 */
export function normaliseRecoveryCode(input: string): string {
  return input
    .toUpperCase()
    .replace(/[^0-9A-Z]/g, "")
    .replace(/[IL]/g, "1")
    .replace(/O/g, "0");
}

/** SHA-256 hex of the normalised code — the only form that is ever stored. */
export function hashRecoveryCode(code: string): string {
  return createHash("sha256").update(normaliseRecoveryCode(code)).digest("hex");
}
