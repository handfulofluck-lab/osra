# Future CI candidates (#614)

These are proposals only; no check was added in this issue.

1. **Resource-key parity:** every key in `app_en.arb` exists in `app_ar.arb`; every Android `values/strings.xml` key exists in `values-ar/strings.xml`; every iOS English `.strings` key exists in its Arabic counterpart. Report missing keys, not missing translations by different key names.
2. **Hard-coded UI strings:** flag direct Flutter `Text('…')`, Kotlin view/notification text, Swift `Text("…")`, and WinForms labels that do not use a localization resource. Keep SQL, logs, protocol values and decoder internals out of the check.
3. **Website language coverage:** every English HTML page has an Arabic counterpart or an explicit reviewed exemption. Include visible metadata and accessibility labels as well as body text.
4. **Embedded API bilingual blocks:** when an email or account page has an English block, require the corresponding Arabic block rather than only checking for Arabic characters somewhere in the file.
5. **Mutation tests:** each new guard must fail on a missing key, a hard-coded literal, and an already-translated page that must not be reported as missing.
