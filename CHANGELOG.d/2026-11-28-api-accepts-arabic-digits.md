### API — codes and MFA digits are normalised on the server too (#771)

The client halves of #771 shipped earlier (`#818` Android, `#819` parent, `#820` Windows), so a parent typing `١٢٣٤` on an Arabic keyboard is normalised before the app sends anything. This adds the same normalisation on the **server**, which is the half that still mattered:

- `services/api/src/lib/digits.ts` maps Arabic-Indic `٠–٩` (U+0660–U+0669) and Extended Arabic-Indic `۰–۹` (U+06F0–U+06F9) to `0–9`, strips only plain spaces and LRM/RLM/ALM, and returns `null` for any other character — so a code containing a letter is still rejected, never silently coerced.
- Applied before **every** comparison and hash on the auth paths: TOTP verification (`mfaVerify.ts`), MFA-reset code hashing and matching (`mfaReset.ts`), the account-deletion re-auth schema (`accountDeletion.ts`), and the pairing-code routes (`auth.ts`, `devices.ts`).
- No error line, wording or response shape changes: after this the existing "not digits" errors fire only for characters that are not digits in any of the three forms.

**Why the server needs it as well:** an APK or an older build that has not been updated still sends the raw Arabic digits, and the server is what decides whether a code matches. Without this, those builds pair or sign in only when the keyboard sends ASCII.

Tests: `services/api/test/digit-normalization.test.ts` — 6 rows covering the normaliser, TOTP verification with both Arabic families, reset-code hash/match, the re-auth schema, and a pairing-code route check. No wording change is claimed because none was made.
