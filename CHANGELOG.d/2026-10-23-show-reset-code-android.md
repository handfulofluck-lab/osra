### Child agent — the family-witness reset code on the child's phone (ADR-0031, #297)

The Android half of ADR-0031: when a locked-out parent clicks the mailbox link, `show_reset_code`
now reaches the paired child device and is rendered, so a family can complete the device-code witness.

- **The screen** — `apps/child-android/app/src/main/java/com/familyshield/agent/commands/ResetCodeActivity.kt`:
  a full-screen notice naming the parent from the payload, the 8-digit code in large monospaced type
  grouped as `1234 5678` and **forced `TextDirection.Ltr`**, so an Arabic (RTL) paragraph cannot
  render it as `5678 1234` and send the parent to a wrong entry, and its validity read from the
  payload's own `expiresAt` (not a hardcoded ten minutes) as an Android plural
  (`res/plurals` — `one`/`other` in English, all six CLDR quantities in Arabic, because "10 دقيقة"
  is ungrammatical). The copy tells the child to show the code only to their parent **in person**
  and never to send it or read it out on a call; a second line tells the child to refuse anyone else
  and tell a grown-up they trust. A blank `parentName` uses generic wording instead of refusing the
  notice. Back and Close both leave — it restricts nothing (ADR-0019).
- **Withdrawal closes, it does not accuse** — the screen tells its own expiry apart from any other
  reason the notice disappears (`ResetCodePolicy.viewOf`). A withdrawal usually means the parent just
  typed the code, so the notice closes; the expired copy ("ask your parent to start again") is kept
  for real expiry only.
- **Trigger and notification** — `CommandDispatcher` handles the type (`commands/CommandDispatcher.kt`)
  with the existing `startActivity(NEW_TASK)` idiom used by `LockActivity`/`RingActivity`, so a
  backgrounded app still raises it. It also posts a notification on the existing parent-command
  channel that **never carries the code**, worded "tap to see it, show it in person": that is what a
  locked phone shows (the activity is deliberately not `showWhenLocked`), and the only way in when
  neither the overlay nor accessibility can launch the screen. The command is refused
  `reset_code_screen_unavailable` only when there is no notification either. The manifest activity is
  `singleTask`, `excludeFromRecents`, `turnScreenOn`, and deliberately **not** `showWhenLocked`
  (issue #87: never cover the keyguard's PIN pad).
- **Auto-clear** — the notice stops showing the code at `expiresAt` (one-second foreground tick on
  the visible notice, no WorkManager/background timer). A withdrawal is the API clearing the payload
  (`payload = {}`): the same row arrives again on the existing 120-second redelivery, the notice
  closes and its notification is cancelled.
- **Ack** — deliberately deferred (`CommandOutcome.Deferred`). Acking at display time would clear the
  plaintext payload server-side before the parent could read it **and** stop the redelivery that
  carries a withdrawal, so the row stays `delivered` while the notice is up and is acked `ok` with
  `detail.screen = expired|dismissed` when it ends; the dispatcher acks `withdrawn` when the API
  clears the payload and `superseded` when a newer code replaces an older one. The ack goes through
  `CommandDispatcher.ackResetCode` — the `ackLocateNow` shape, with its application scope and
  log-once rule — rather than a second ack path inside the Activity. No API semantics were changed.
- **Strings** — `res/values/strings.xml` and `res/values-ar/strings.xml`; the Arabic copy is real
  Arabic, not a transliteration, and is still queued for the native-speaker review on Karim's list.
- **Tests** — `ResetCodePolicyTest` (22: payload parsing/validation, a blank parent name kept rather
  than refused, `1234 5678` formatting, inclusive expiry, remaining-minutes rounding, the
  show/expired/close view, withdrawal vs malformed, notification-only as a screen path, the ack
  detail for every ending, state replacement/withdrawal), `ResetCodeStringsTest` (9: EN/AR key parity
  across strings **and plurals**, Arabic characters, the generic unnamed intro, the "in person"/"do
  not send" instruction, the "refuse and tell a trusted adult" line, the Arabic plural forms, and a
  notification string that takes no placeholder) and `ResetCodeWiringTest` (12: the dispatcher route,
  the deferred ack, `canShowScreen = canLaunch || canNotify`, a notification that never reads
  `notice.code`, the Notice/notification withdrawal pair, the withdrawal close, `TextDirection.Ltr`
  on the code, the blank-name fallback, the plural read, the dispatcher ack path, the banner-free
  intent, `detail.screen = superseded`, and the manifest's
  `singleTask`/`turnScreenOn`/no-`showWhenLocked` shape). All are JVM suites in
  `testPlayDebugUnitTest` / `testFullDebugUnitTest`.

**Gates (this branch, author-run after the review):** `./gradlew testFullDebugUnitTest
testPlayDebugUnitTest` → **602 tests per flavour, 0 failures, 0 errors, 0 skipped** (83 suites;
baseline 590), `BUILD SUCCESSFUL`. `node scripts/check-changelog-fragment.mjs --base origin/main` and
`node scripts/check-docs-links.mjs` are green from the worktree root.

**Not verified in this change:** no instrumentation or hardware row was run — the notice's
appearance, the notification behind the keyguard, background-activity launch on a real OEM, the
Arabic plural the device selects and Arabic shaping/RTL need a device and are out of scope. The
withdrawal close, the LTR direction and the plural are pinned at the policy and source-wiring level
(`ResetCodePolicy.viewOf`, `ResetCodeWiringTest`), not observed. The deferred-ack design also means a
withdrawal can only be observed while the row is still being redelivered (up to three attempts,
roughly six minutes); after that a withdrawn code clears at its own ten-minute expiry. If
notifications are disabled **and** the overlay app-op and accessibility service are both off, the
command is acked `failed` with `reset_code_screen_unavailable` rather than shown.

- **`android:taskAffinity=""` on the activity, added after a phone row (#312 review).** Without it the notice is
  hosted by the app's main task, so Close/Back landed on `PairingActivity` instead of returning to whatever the child
  was doing. Measured on the handset by Claude: with the attribute, closing returns to the previous app. Pinned by a
  manifest assertion in `ResetCodeWiringTest`.

