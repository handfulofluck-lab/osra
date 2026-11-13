### OSRA Kids for iPhone — the block and bedtime screens follow an Arabic phone (#654)
- **Before:** with the iPhone set to Arabic, the shield's title and buttons stayed English. The three extensions
  declared only their development language and had no `.lproj`, so iOS treated each one as English-only.
- **After:** the app and all three extensions list `en` and `ar` in `CFBundleLocalizations`. Each extension also
  carries an empty `en.lproj` and `ar.lproj` (`InfoPlist.strings` with no keys), so the built `.appex` is
  localized in both. No visible string changed.
- `scripts/check-app-bundle.py` check 7 fails CI when the app or an `.appex`, built or in the source tree, lacks
  either language. On `main` it reports 10 problems.
- Debug builds log `shield_language preferred=… bundle=… chosen=…` from the shield, for the device row that
  confirms the cause.
