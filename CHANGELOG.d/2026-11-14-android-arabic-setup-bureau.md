### Android child — the Arabic setup and status screens, with the Bureau's corrections and its section 9 (#709, #725)
- The Arabic Language Bureau's review of #725 (13 Nov 2026, comment 6861740969) asked for two corrections and
  supplied the lines its first sweep had left English. Both are in this head, every value copied from the
  Bureau's template.
- `values-ar/strings.xml`: `onboarding_grant_private_dns_title` reads «إعداد DNS الخاص غير مضبوط على مزوّد»;
  the «إعداد » prefix stops the line starting with a Latin word, which Android lays out left to right
  (#717's Flip4 pictures).
- The status screen's missing-names line is now a resource pair, the Bureau's template: `status_missing`
  («الناقص: %1$s») and `list_separator` («، »). `PairingActivity` formats the line itself instead of
  concatenating a label and splitting on `joinToString`'s Latin comma, so the names join with the Arabic
  comma on an Arabic phone and the visible English is still `Missing: a, b`. `status_missing_label` is left
  in place, unused, rather than removed in this PR.
- Nine lines the Bureau decided (its section 9) now speak Arabic: the six lock and pause overlay lines, the
  SOS button («استغاثة»), the location notification channel name, and the quick-settings tile
  («الاستغاثة»). `sos_tile_label` therefore leaves `ChildSystemStringsTest`'s brand-name list, which the
  Bureau withdrew on 13 Nov; `app_name` stays in that list, its Arabic being its own PR.
- `list_separator` is written quoted (`, ` and «، » wrapped in double quotes) in both files: aapt2 trims an
  unquoted trailing space, and a separator compiled to a bare comma ran the names together. Checked with
  `aapt2 dump resources` against the built APK, not assumed.
- Kept out on purpose, to the Bureau's follow-up PR: `app_name`'s Arabic, the five PIN error strings, the two
  device-admin texts (`DeviceAdminManager.kt`, `GuardianAdminReceiver.kt`) and sheet 2.
- Gates run on this head by the author, unverified by another member and **not** run on a handset:
  `./gradlew testPlayDebugUnitTest --no-daemon` — BUILD SUCCESSFUL in 4m 33s, **1053 tests, 0 failed**
  (151 XML suites; Gradle prints no count line when nothing fails); `./gradlew assembleDebug --no-daemon` —
  BUILD SUCCESSFUL in 29m 4s, both debug flavours packaged.
- The separator was checked in the packaged APK rather than assumed: `aapt2 dump resources` on
  `app-play-debug.apk` reports `list_separator` as `", "` for the default locale and `"، "` for `(ar)`.
