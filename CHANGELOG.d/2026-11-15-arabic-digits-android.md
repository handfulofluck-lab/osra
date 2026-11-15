### Android: Arabic-Indic digits are the same digits in a PIN and a pairing code (#771)
- An Arabic keyboard can type `٠–٩`, and an Urdu or Persian one `۰–۹`, into the numeric fields. Android's
  `isDigit()` accepted them, so a PIN set with those digits was hashed as typed and did not match the
  same PIN typed later on a Western keyboard; the pairing-code regex accepted them and sent them as typed.
- `Digits.normalize` (child app) maps both families to `0–9`. `ParentPin.validationError`, `hash` and
  `verify` normalise before the check, the hash and the comparison; the pairing form and the QR decoder
  normalise before validation and before the claim. The PIN confirmation compares normalised values, so
  the two fields may be typed with different keyboards.
- A PIN stored **before** this change from Arabic digits was hashed as typed. There are no outside users
  yet; such a PIN must be set again. `DigitsTest`, `ParentPinTest` and `PairQrPayloadTest` pin the
  round-trips in both directions.
