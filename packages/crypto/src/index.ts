import { createCipheriv, createDecipheriv, createHmac, hkdfSync, randomBytes } from "node:crypto";

/** Base64-encoded AES-256-GCM payload produced by encryptForFamily. */
export interface FamilyCipherPayload {
  /** Base64-encoded 12-byte initialization vector. */
  iv: string;
  /** Base64-encoded ciphertext. */
  ciphertext: string;
  /** Base64-encoded 16-byte GCM authentication tag. */
  tag: string;
}

/** Generate a new random 32-byte AES-256 family key, base64-encoded. */
export function generateFamilyKey(): string {
  return randomBytes(32).toString("base64");
}

/** Encrypt plaintext for a family using AES-256-GCM; returns base64 iv/ciphertext/tag. */
export function encryptForFamily(plaintext: string, base64Key: string): FamilyCipherPayload {
  const key = Buffer.from(base64Key, "base64");
  const iv = randomBytes(12);
  const cipher = createCipheriv("aes-256-gcm", key, iv);
  const ciphertext = Buffer.concat([cipher.update(plaintext, "utf8"), cipher.final()]);
  return {
    iv: iv.toString("base64"),
    ciphertext: ciphertext.toString("base64"),
    tag: cipher.getAuthTag().toString("base64"),
  };
}

/** Decrypt a FamilyCipherPayload; throws on wrong key or any tampering. */
export function decryptForFamily(payload: FamilyCipherPayload, base64Key: string): string {
  const key = Buffer.from(base64Key, "base64");
  const decipher = createDecipheriv("aes-256-gcm", key, Buffer.from(payload.iv, "base64"));
  decipher.setAuthTag(Buffer.from(payload.tag, "base64"));
  const plain = Buffer.concat([
    decipher.update(Buffer.from(payload.ciphertext, "base64")),
    decipher.final(),
  ]);
  return plain.toString("utf8");
}

/** Derive a per-device 32-byte key via HKDF-SHA256 (salt = deviceId, info = "familyshield-device"). */
export function deriveDeviceKey(masterKey: string, deviceId: string): string {
  const ikm = Buffer.from(masterKey, "base64");
  const okm = hkdfSync("sha256", ikm, deviceId, "familyshield-device", 32);
  return Buffer.from(okm).toString("base64");
}

/** Compute hex HMAC-SHA256 of body under secret (for X-FamilyShield-Signature headers). */
export function hmacSign(body: string | Buffer, secret: string): string {
  return createHmac("sha256", secret).update(body).digest("hex");
}
