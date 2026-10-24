### Parent app — Create account says what is wrong instead of "Validation failed" (3.2)
- Found in the first timed five-minute setup run (2026-10-23). A password under 12 characters made Register
  answer "Validation failed". It named neither the field nor the server's 12-character minimum
  (`RegisterSchema` in `services/api/src/routes/auth.ts`), so a non-engineer had no way to recover.
- The Create account section now opens with one line: it uses the email and password above, and the
  password needs at least 12 characters. The section has no email or password field of its own,
  which the old screen never said.
- Before any request goes out, the form checks, in field order: an email with an `@`, a password of at
  least 12 characters, and both names. The first problem shows beside the Register button, not above
  Sign in, so a parent filling in the form can see it.
- A server rejection is named by field. `AuthNotifier` now keeps zod's rejected field names
  (`validation_failed:email,password`, sorted). The screen maps them to "Enter a valid email address.",
  "The password is too short…", "Enter your name and a family name." or a general sentence. `409
  email_taken` says the account exists and points to Sign in. Both apply in the first-run wizard and on
  the plain screen. Every other sign-in message is unchanged, including the plain screen's raw
  `invalid_credentials`.
- Six new ARB keys in English and Arabic. `test/register_errors_test.dart` has 11 cases: the rule
  line, the 11/12-character boundary, each pre-send check, a server field error, a taken email,
  Sign in moving the message back, Arabic, and the provider's field list.
