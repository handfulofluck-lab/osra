import { pbkdf2 as pbkdf2Callback, randomBytes, timingSafeEqual } from "node:crypto";
import { promisify } from "node:util";

/**
 * #1108: "Change device PIN" — the server side of a parent setting a new OSRA PIN on a child's phone.
 *
 * Ahmed's R3 ruling (7151514667) picked option A: the parent app sends the PIN over TLS, the API checks it
 * against the same rules the phone uses (`docs/test-vectors/parent-pin.tsv`) and derives the storable hash in
 * memory, and only that hash ever leaves this process — inside one short-lived `DeviceCommand` row. The PIN
 * itself is never stored, logged or returned, and nothing anywhere reads a PIN or a hash back.
 *
 * The format is the child agent's (`apps/child-android/.../security/ParentPin.kt`), byte for byte:
 * `pbkdf2$<iterations>$<base64 16-byte salt>$<base64 32-byte PBKDF2-HMAC-SHA256>`, computed over the PIN with
 * Arabic-Indic and Extended Arabic-Indic digits normalised to ASCII first (#771).
 */
export const PARENT_PIN_KDF = { iterations: 120_000, saltBytes: 16, keyBytes: 32, digest: "sha256" } as const;
export const PARENT_PIN_MIN_LENGTH = 4;
export const PARENT_PIN_MAX_LENGTH = 8;

/** The same list as `ParentPin.WEAK_PINS` on the phone; the shared vectors pin both. */
const WEAK_PINS = new Set(["1234", "0000", "1111", "1212", "12345", "123456", "111111", "654321"]);

const pbkdf2 = promisify(pbkdf2Callback);

/** `٠–٩` (U+0660) and `۰–۹` (U+06F0) become `0–9`; everything else is left as typed. */
export function normalizePinDigits(pin: string): string {
  return pin.replace(/[٠-٩۰-۹]/g, (c) => {
    const code = c.charCodeAt(0);
    return String(code >= 0x06f0 ? code - 0x06f0 : code - 0x0660);
  });
}

/** Null when acceptable, else the phone's own refusal sentence (the tsv's `validate` rows). */
export function parentPinValidationError(pin: string): string | null {
  const normalized = normalizePinDigits(pin);
  if (normalized.length < PARENT_PIN_MIN_LENGTH) return `PIN must be at least ${PARENT_PIN_MIN_LENGTH} digits.`;
  if (normalized.length > PARENT_PIN_MAX_LENGTH) return `PIN must be at most ${PARENT_PIN_MAX_LENGTH} digits.`;
  if (!/^[0-9]+$/.test(normalized)) return "PIN must be digits only.";
  if (new Set(normalized).size === 1) return "Choose a PIN that is not all the same digit.";
  if (WEAK_PINS.has(normalized)) return "Choose a less predictable PIN.";
  return null;
}

/** Machine reason for the parent app, which shows its own localised sentence. */
export function parentPinRefusalCode(pin: string): "pin_too_short" | "pin_too_long" | "pin_not_digits" | "pin_weak" | null {
  const normalized = normalizePinDigits(pin);
  if (normalized.length < PARENT_PIN_MIN_LENGTH) return "pin_too_short";
  if (normalized.length > PARENT_PIN_MAX_LENGTH) return "pin_too_long";
  if (!/^[0-9]+$/.test(normalized)) return "pin_not_digits";
  if (new Set(normalized).size === 1 || WEAK_PINS.has(normalized)) return "pin_weak";
  return null;
}

/** Hash a PIN that passed [parentPinValidationError], with a fresh 16-byte random salt (condition 3). */
export async function hashParentPin(pin: string, salt: Buffer = randomBytes(PARENT_PIN_KDF.saltBytes)): Promise<string> {
  const key = await pbkdf2(normalizePinDigits(pin), salt, PARENT_PIN_KDF.iterations, PARENT_PIN_KDF.keyBytes, PARENT_PIN_KDF.digest);
  return `pbkdf2$${PARENT_PIN_KDF.iterations}$${salt.toString("base64")}$${key.toString("base64")}`;
}

/** The exact shape the phone accepts in `setPrehashed`; anything else is refused there too. */
const PREHASHED = /^pbkdf2\$120000\$([A-Za-z0-9+/]{22}==)\$([A-Za-z0-9+/]{43}=)$/;

export function isPrehashedParentPin(value: unknown): value is string {
  if (typeof value !== "string") return false;
  const m = PREHASHED.exec(value);
  if (!m) return false;
  return Buffer.from(m[1], "base64").length === PARENT_PIN_KDF.saltBytes && Buffer.from(m[2], "base64").length === PARENT_PIN_KDF.keyBytes;
}

/**
 * Test-side check that a stored value matches a PIN. Production never verifies a parent PIN on the server —
 * the phone does — but the shared vectors are read through this so the API's KDF is proven to be the phone's.
 */
export async function verifyParentPinForTest(pin: string, stored: string): Promise<boolean> {
  const parts = stored.split("$");
  if (parts.length !== 4 || parts[0] !== "pbkdf2") return false;
  const iterations = Number(parts[1]);
  if (!Number.isInteger(iterations) || iterations <= 0) return false;
  const normalized = normalizePinDigits(pin);
  if (normalized.length < PARENT_PIN_MIN_LENGTH || normalized.length > PARENT_PIN_MAX_LENGTH) return false;
  const salt = Buffer.from(parts[2], "base64");
  const expected = Buffer.from(parts[3], "base64");
  const actual = await pbkdf2(normalized, salt, iterations, expected.length || PARENT_PIN_KDF.keyBytes, PARENT_PIN_KDF.digest);
  return actual.length === expected.length && timingSafeEqual(actual, expected);
}
