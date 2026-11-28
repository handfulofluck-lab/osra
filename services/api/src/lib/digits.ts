import { z } from "zod";

export function normalizeDigits(value: string): string | null {
  let normalized = "";
  for (const character of value) {
    const codePoint = character.codePointAt(0)!;
    if (codePoint >= 0x30 && codePoint <= 0x39) {
      normalized += character;
    } else if (codePoint >= 0x660 && codePoint <= 0x669) {
      normalized += String.fromCharCode(codePoint - 0x660 + 0x30);
    } else if (codePoint >= 0x6f0 && codePoint <= 0x6f9) {
      normalized += String.fromCharCode(codePoint - 0x6f0 + 0x30);
    } else if (codePoint !== 0x20 && codePoint !== 0x200e && codePoint !== 0x200f && codePoint !== 0x61c) {
      return null;
    }
  }
  return normalized;
}

/** The shape a code must have after normalisation: exactly [length] ASCII digits and nothing else.
 *  A refused character becomes `""` rather than `null`, so the pipe reports the same `Invalid` message this
 *  field produced before (#771): sending `null` into the string check printed `Expected string, received null`,
 *  a user-visible wording change Codex caught in review. */
export const digitsSchema = (length: number) =>
  z
    .string()
    .transform((value) => normalizeDigits(value) ?? "")
    .pipe(z.string().regex(new RegExp(`^\\d{${length}}$`)));
