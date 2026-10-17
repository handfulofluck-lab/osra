import { createHash } from "node:crypto";
import { decryptForFamily, encryptForFamily } from "@familyshield/crypto";

// NOTE: VAULT_KEY should be a base64 32-byte AES key (see @familyshield/crypto generateFamilyKey)
// in production. Dev fallback derives a deterministic key from JWT_SECRET so local stacks boot
// without extra config — never rely on it outside dev/test.
function getVaultKey(): string {
  if (process.env.VAULT_KEY) return process.env.VAULT_KEY;
  if (process.env.NODE_ENV === "production") throw new Error("VAULT_KEY is required in production");
  // Same dev fallback secret as server.ts uses for JWT_SECRET, so unit tests and bare dev stacks boot.
  return createHash("sha256").update(process.env.JWT_SECRET ?? "dev-insecure-jwt-secret").digest("base64");
}

/** Encrypt a captured message snippet for the server-side vault; returns a JSON-storable string. */
export function encryptSnippet(plaintext: string): string {
  return JSON.stringify(encryptForFamily(plaintext, getVaultKey()));
}

/** Decrypt a vault-stored snippet; returns "" when the stored payload is undecryptable. */
export function decryptSnippet(stored: string): string {
  try {
    return decryptForFamily(JSON.parse(stored), getVaultKey());
  } catch {
    return "";
  }
}
