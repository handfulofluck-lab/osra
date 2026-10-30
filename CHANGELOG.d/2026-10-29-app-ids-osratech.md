### Play identities — `com.osratech.child` and `com.osratech.parent`, with the agent's self-exemption derived (#442, Karim's decision 2B)
- **Why now.** Play freezes an application id forever once anything is uploaded, internal testing included,
  so the rename had to happen before the first upload rather than after. Karim decided the ids on
  2026-10-29: child agent `com.familyshield.agent` → **`com.osratech.child`**, parent app
  `dev.familyshield.familyshield_parent` → **`com.osratech.parent`**.
- **Only the `applicationId`.** `namespace`, the Kotlin/Dart package names and therefore every component
  name are untouched — hundreds of source files, proguard's class-name keeps and the manifest entries stay
  as they were. The installed identity is the one thing that moved.
- **The functional trap, closed.** `EssentialPackages.OWN_PACKAGE` was a **second copy** of the id
  (`"com.familyshield.agent"`), which is the one package the app-block overlay must never cover. Left as a
  literal, the rename would have made the agent stop recognising its own windows and let a block rule
  cover its own overlay and lock screens. It is now `BuildConfig.APPLICATION_ID`, so it cannot disagree
  with what the OS installed. This is also the guard `docs/QA/VERIFICATION-LEDGER-2026-10-19.md:957`
  records as asked-for and **not delivered** on #199 item 4.
- **The row that can fail.** `OWN_PACKAGE == BuildConfig.APPLICATION_ID` is *true by construction* once the
  value is derived, so it is not written as a test. `EssentialPackagesTest` instead reads the source and
  rejects a string literal in that declaration — reintroduce `const val OWN_PACKAGE = "…"` and it goes red.
- **The merged-manifest consequence.** `androidx.core` declares
  `${applicationId}.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION`, so the reviewed Play allow-list moves with
  the id; the merged-manifest gate is what proves the value rather than a comment.
- **Scripts and docs that drive a phone by package name** now use the new id: the bypass probe, the pairing
  timer, the signing run, the app-list cadence check, and every `adb` command in `docs/TESTING.md` and the
  tester README. **The component form changed shape:** `dpm` takes `package/class`, and the class keeps the
  old namespace, so `com.osratech.child/.security.GuardianAdminReceiver` — the relative form that worked
  while package and namespace were equal — now resolves to a class that does not exist. It is spelled
  `com.osratech.child/com.familyshield.agent.security.GuardianAdminReceiver`.
- **Not in this change:** the iOS bundle ids, the app group and `APNS_DEVICE_BUNDLE_ID` (Ahmed's separate
  PR, before the first App Store Connect upload), and registering both ids in the Firebase project, which
  is a console step with Karim's account — until then a build has no FCM token. No hardware row is claimed
  here: installing the new agent *beside* the old one and confirming it blocks an app while not blocking
  itself is the Flip4 row.
