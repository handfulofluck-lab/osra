### Android: Arabic-Indic digits are the same digits in a PIN and a pairing code (#771)
- An Arabic keyboard can type `٠–٩`, and an Urdu or Persian one `۰–۹`, into the numeric fields. Android's
  `isDigit()` accepted them, so a PIN set with those digits was hashed as typed and did not match the
  same PIN typed later on a Western keyboard. The pairing-code regex (`\d`, ASCII-only on the JVM)
  rejected them with the code error, so the code could not be typed at all.
- `Digits.normalize` (child app) maps both families to `0–9`. `ParentPin.validationError`, `hash` and
  `verify` normalise before the check, the hash and the comparison; the pairing form and the QR decoder
  normalise before validation and before the claim. The PIN confirmation compares normalised values, so
  the two fields may be typed with different keyboards.
- A PIN stored **before** this change from Arabic digits was hashed as typed. It still opens when typed
  the same way: `verify` accepts that exact stored form as a second path, and `ParentPinStore` re-hashes
  the normalised PIN on that first successful use, so the legacy value then disappears. `DigitsTest`,
  `ParentPinTest` (including the legacy hash and its upgrade) and `PairQrPayloadTest` pin the
  round-trips in both directions.
