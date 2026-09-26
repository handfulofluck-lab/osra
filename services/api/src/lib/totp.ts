import { createHmac, randomBytes } from "node:crypto";

const B32_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";

/** Encode a buffer as RFC 4648 base32 (no padding). */
export function base32Encode(buf: Buffer): string {
  let bits = 0;
  let value = 0;
  let out = "";
  for (const byte of buf) {
    value = (value << 8) | byte;
    bits += 8;
    while (bits >= 5) {
      out += B32_ALPHABET[(value >>> (bits - 5)) & 31];
      bits -= 5;
    }
  }
  if (bits > 0) out += B32_ALPHABET[(value << (5 - bits)) & 31];
  return out;
}

/** Decode an unpadded base32 string back to bytes. */
export function base32Decode(encoded: string): Buffer {
  let bits = 0;
  let value = 0;
  const out: number[] = [];
  for (const ch of encoded.toUpperCase()) {
    const idx = B32_ALPHABET.indexOf(ch);
    if (idx === -1) continue;
    value = (value << 5) | idx;
    bits += 5;
    if (bits >= 8) {
      out.push((value >>> (bits - 8)) & 255);
      bits -= 8;
    }
  }
  return Buffer.from(out);
}

/** Generate a new random base32 TOTP secret (160 bits). */
export function generateTotpSecret(): string {
  return base32Encode(randomBytes(20));
}

/** Compute the TOTP code for a counter value (HMAC-SHA1, 6 digits). */
export function totpAtCounter(secretB32: string, counter: number): string {
  const key = base32Decode(secretB32);
  const msg = Buffer.alloc(8);
  msg.writeBigUInt64BE(BigInt(counter));
  const digest = createHmac("sha1", key).update(msg).digest();
  const offset = digest[digest.length - 1] & 0x0f;
  const binary =
    ((digest[offset] & 0x7f) << 24) |
    (digest[offset + 1] << 16) |
    (digest[offset + 2] << 8) |
    digest[offset + 3];
  return (binary % 1_000_000).toString().padStart(6, "0");
}

/** Verify a 6-digit TOTP code against a base32 secret with a ±1 step window. */
export function verifyTotp(secretB32: string, code: string, stepSeconds = 30): boolean {
  const counter = Math.floor(Date.now() / 1000 / stepSeconds);
  for (const window of [-1, 0, 1]) {
    if (totpAtCounter(secretB32, counter + window) === code) return true;
  }
  return false;
}
