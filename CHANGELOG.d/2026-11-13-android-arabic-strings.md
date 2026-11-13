### OSRA Kids for Android — the screens that stayed English on an Arabic phone (#709)
- **Before:** the SOS screen, the parent-PIN gate, the ring screen, the QR scanner, the setup checklist and the
  status screen, and the child's notifications were English words typed into the Kotlin, so an Arabic phone
  still showed English on every one of them. `values/strings.xml` held 67 keys and the rest had no resource.
- **After:** 124 new keys in `values/strings.xml` (67 → 191, three of them plurals), read through `getString`
  and `stringResource` instead of a literal in the code. 116 of them carry the Arabic Language Bureau's
  approved wording, copied byte for byte from its 13 Nov sweep
  (`docs/localization/2026-11-13-sweep-614-arabic.md` on #605); `values-ar` goes from 64 keys to 180. Arabic
  needs all five of its plural forms, so "Screen will lock in N minutes" and "Finish protection (N to grant)"
  are `<plurals>` in both files with `zero/one/two/few/many/other`.
- **Eleven keys stay English-only, and the test names them.** `app_name`, `app_name_ar` and `sos_tile_label`
  keep no Arabic override: `ChildSystemStringsTest`
  (`apps/child-android/app/src/test/java/com/familyshield/agent/ChildSystemStringsTest.kt:67-68`) holds that
  rule, and the sweep does offer «الاستغاثة» for the tile — so the tile label is its owner's call, not this
  change's. The other eight — the SOS button, the six lock/pause overlay lines, and the location channel name
  in Settings — have no line in the sweep's Android section. Separately, `OnboardingPolicy.oemHint`'s seven
  phone-maker menu paths stay English in the code on purpose: the sweep holds them until they can be read off
  an Arabic handset.
- Rows: `ChildScreenStringsTest` (6 tests) holds that every string is either translated or named as
  English-only, that `%1$s`/`%2$d` survive every translation, that each screen reads its words from resources
  rather than its own copy, and that the three policies which still hold English for their own unit rows
  (`OnboardingPolicy.progressLine`, `LocationStatusPolicy.line`, `AdminEnrolmentMessages`) say the same
  sentence as their resource, so the two copies cannot drift. Mutation: deleting `sos_need_help` from
  `values-ar` turns `every key the sweep covers has Arabic, and nothing else does` red.
- Gates: `testPlayDebugUnitTest` 994 tests / 0 failed, `testFullDebugUnitTest` 994 / 0 failed,
  `:app:assembleFullDebug` green, `check-merged-manifest-gate.mjs` green. **Not verified here:** how the Arabic
  shapes and lays out on a phone — that needs the handset and a held lease.
