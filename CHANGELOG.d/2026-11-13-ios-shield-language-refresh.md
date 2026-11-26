### OSRA Kids for iPhone — the shield follows a language change (#732)
- **Before:** after the phone's language was changed, the shield kept the old language until the app was
  reinstalled. On a real iPhone the extension's own view of the language (`Locale.preferredLanguages`,
  `AppleLanguages`, its bundle's localization) stayed at the old language, even in a fresh extension process.
- **After:** the main app records the language it runs in to the app group (`SharedLanguage`), at launch and on
  `NSLocale.currentLocaleDidChangeNotification`; iOS relaunches the app after a language change. The shield reads
  that first (`ShieldText.resolvedLanguage`), and its own fresh read of the preferences is the fallback.
- **Known gap:** if OSRA Kids has not been opened since the switch, the shield keeps the last recorded language until
  it is. The parent guide (#680) says so. Debug builds log every language source the shield sees.
- Rows (`ShieldTextTests`): the recorded language wins over the extension's read, nothing recorded falls back, an
  unshipped value is ignored, recording maps preferences to a shipped language, and source rows keep the app
  recording at launch and on a locale change.
