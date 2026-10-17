import { decryptSnippet, encryptSnippet } from "./snippetVault.js";

/**
 * At-rest encryption for small server-held secrets (ADR-0014): today the parent's TOTP secret.
 * Stored as `enc1:<vault json>` under `VAULT_KEY`; a value without the prefix is a legacy
 * plaintext row and is re-encrypted the next time it is read on a write path.
 */
const PREFIX = "enc1:";

export function encryptSecret(plain: string): string {
  return PREFIX + encryptSnippet(plain);
}

export function isEncryptedSecret(stored: string | null | undefined): boolean {
  return typeof stored === "string" && stored.startsWith(PREFIX);
}

/** Returns the plaintext, or "" when the stored value cannot be decrypted. */
export function decryptSecret(stored: string | null | undefined): string {
  if (!stored) return "";
  if (!stored.startsWith(PREFIX)) return stored; // legacy plaintext
  return decryptSnippet(stored.slice(PREFIX.length));
}
