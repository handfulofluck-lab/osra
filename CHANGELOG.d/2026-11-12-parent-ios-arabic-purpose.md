### Parent app on iPhone — the Arabic purpose string and the app's Arabic name (#616 follow-up)
- **Before:** #647 shipped the location purpose string in English only, so an iPhone set to Arabic showed an
  English sentence where its system prompt would quote our purpose. Apple accepted build 2 regardless; the
  sentence is what a parent reads.
- **After:** `apps/parent-app/ios/Runner/ar.lproj/InfoPlist.strings` carries the wording Karim approved and the
  Arabic Language Bureau published byte for byte on #604 —
  «لا يستخدم تطبيق أسرة موقعك. تعرض خريطة العائلة مكان هاتف طفلك فقط.» — and, in the same file,
  `CFBundleDisplayName = "أسرة"` (Karim's choice, 12:56Z): on a phone set to Arabic the app is named «أسرة»
  under its icon instead of «OSRA».
- **The file is wired, not merely present.** One `PBXFileReference` and one child in the existing
  `InfoPlist.strings` variant group, because a file in `ar.lproj/` that the project does not reference never
  reaches the bundle — the same trap #410 and #647 both hit.
- **The guard now covers both locales.** `parent-app.yml` asserts the purpose string non-empty in `en` **and**
  `ar`, and the Arabic display name non-empty, all read from `build/ios/iphoneos/Runner.app`, so a missing
  reference fails the build rather than shipping English to an Arabic phone.
- **Wording is not ours to change.** Rewording either line needs a new Arabic Language Bureau line on #604;
  the file says so at the top.
- **Not verified here:** no iOS toolchain on this host. The pbxproj edit and the extended guard are proven by
  the parent iOS job, which is where #647's guard first ran green.
