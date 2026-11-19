### Parent app — the picker's failure is a sentence, and an app nothing reports is named, not numbered (#872 conditions 1, 2)
- **Condition 1:** `installedAppsLoadFailed` is now a whole sentence with no `{error}` placeholder —
  "Couldn't load apps. Check your connection and try again." / «تعذّر تحميل التطبيقات المثبتة. تحقّق من اتصال
  الإنترنت ثم حاول مرة أخرى.» — the exact pair the UI/UX and Arabic Language Bureaus issued, so the picker
  stops appending a `DioException` to it.
- **Condition 2, to Claude's data shape** (`alwaysAllowedApps` stays `string[]`, name resolved at display time):
  a new `appDisplayName`/`appDisplayAvatar` pair reads the name and icon from the child's installed-apps
  report, and when nothing reports the id — or a rule's saved name is the id itself — it shows the Bureaus'
  line "App no longer installed" with a "?" avatar instead of the package id. Applied to the always-allowed
  chips, the app-rule rows and the routine chips, which all shared the same `?? id` fallback.
- Two existing rows changed because they asserted the old behaviour, and that is the point of them: the
  phase-5 chip row expected `com.edu.app` on screen, and the picker row expected "Could not load apps: …".
- **Clash for the Bureaus, not fixed here:** #871 carries the same `installedAppsLoadFailed` key with the
  English "Couldn't load **installed** apps. …". Whichever merges second conflicts in `app_en.arb`; the Arabic
  is identical in both. UI/UX Bureau picks one English, as it asked.
- Verified: `flutter test` in `apps/parent-app` is 1003 passed, `flutter analyze` on the rules tree clean.
