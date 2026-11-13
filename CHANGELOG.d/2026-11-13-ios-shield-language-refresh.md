### OSRA Kids for iPhone — the shield follows a language change without a reboot (#732)
- **Before:** after the phone's language was changed with a shield up, the shield extension kept showing the old
  language until an app update or a reboot. Its long-lived process kept the old `Locale.preferredLanguages`.
- **After:** `ShieldText.preferredLanguage` reads the language list afresh on every call
  (`freshPreferredLanguages`: the global `AppleLanguages` after `CFPreferencesAppSynchronize`, with
  `Locale.preferredLanguages` only as the fallback), and the shield resolves it per configuration.
- Rows (`ShieldTextTests`): two calls in one process with different language lists give two languages, an unshipped
  language falls back to English, and a source row keeps the fresh read with no cached language. The device row
  (change language with a shield up, no reinstall) is the Mac test bed's.
