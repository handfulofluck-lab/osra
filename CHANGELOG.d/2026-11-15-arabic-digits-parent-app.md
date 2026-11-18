### Parent app: Arabic-Indic digits in every code and number field (#771)
- An Arabic keyboard types `٠–٩` and an Urdu or Persian one `۰–۹` into a numeric field. The parent
  app's six- and eight-digit checks used Dart's `\d`, which is Western only, so a code typed with those
  digits was refused; the witness-code field filtered with `digitsOnly` and ignored the key press
  altogether; and the sign-in, re-authentication, birth-year and daily-limit fields sent or parsed the
  value as typed.
- `lib/core/digits.dart` adds `normalizeDigits`, used before every check, comparison, `int.tryParse` and
  request: pairing QR encode/decode, the pair screen, MFA enrolment, witness code and the four number
  fields. The witness field now accepts either family as typed and normalises on submit.
- `digits_test.dart` and three `pair_qr_payload_test` rows pin the mapping and both round-trips. The
  pairing payload still emits Western digits, so the child scanner needs no change.
