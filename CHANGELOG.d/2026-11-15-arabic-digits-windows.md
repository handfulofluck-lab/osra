### Windows agent: Arabic-Indic digits are the same parent PIN and pairing code (#771)
- An Arabic keyboard types `٠–٩` and an Urdu or Persian one `۰–۹` into the PIN boxes; the policy accepted
  only ASCII digits, so a parent who set or typed the PIN that way was refused. The same applied to the
  six-digit pairing code, which the server accepts only as `^\d{6}$`.
- `ParentPinPolicy.NormalizeDigits` maps both families to `0–9`. `IsWellFormed`, `Normalize` and `Matches`
  normalise before the check, the legacy-`0000` refusal and the constant-time comparison; a value stored
  from an Arabic keyboard is kept as Western digits. `٠٠٠٠` is still refused as the legacy default.
- `ParentPinPolicy.SamePin` normalises **both** entries, and the pairing dialog's repeat-PIN box uses it,
  so `١٢٣٤` typed twice (or against `1234`) matches; a wrong or missing entry still fails.
- `PairingService.ClaimAsync` normalises the trimmed code once, before the claim, so the dialog and any
  other caller send Western digits to the server.
- Tests: four `WellFormed` rows for the two Arabic families (valid, too short, too long); a four-row
  `NormalizeDigits` theory (mixed `1٢3۴`, an untouched `1ب2`, `٠٠٠٠` → `0000`, `۰۱۲` → `012`); three facts
  (`ArabicDigitsAreTheSamePin`, `TheConfirmBoxMatchesInEitherDigitForm`, the legacy default in either
  form); and the claim-body row in `PairingServiceTests` that sends `١٢٣٤٥٦` and requires `123456`,
  compared ordinally.
