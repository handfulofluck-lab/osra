### Windows agent: Arabic-Indic digits are the same parent PIN (#771)
- An Arabic keyboard types `٠–٩` and an Urdu or Persian one `۰–۹` into the PIN boxes; the policy accepted
  only ASCII digits, so a parent who set or typed the PIN that way was refused.
- `ParentPinPolicy.NormalizeDigits` maps both families to `0–9`. `IsWellFormed`, `Normalize` and `Matches`
  normalise before the check, the legacy-`0000` refusal and the constant-time comparison; a value stored
  from an Arabic keyboard is kept as Western digits. `٠٠٠٠` is still refused as the legacy default.
- `ParentPinPolicyTests` gains four `WellFormed` rows and two facts (round-trips both ways, legacy default
  in either digit form).
