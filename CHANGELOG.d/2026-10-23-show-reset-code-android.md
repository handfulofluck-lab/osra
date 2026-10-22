### Child agent — the family-witness reset code on the child's phone (ADR-0031, #297)

The Android half of ADR-0031: when a locked-out parent clicks the mailbox link, `show_reset_code`
now reaches the paired child device and is rendered, so a family can complete the device-code witness.

- **The screen** — `apps/child-android/app/src/main/java/com/familyshield/agent/commands/ResetCodeActivity.kt`:
  a full-screen notice naming the parent from the payload, the 8-digit code in large monospaced type
  grouped as `1234 5678`, and its validity read from the payload's own `expiresAt` (not a hardcoded
  ten minutes). The copy says the code is for a parent resetting their two-step verification (the
  extra security check when they sign in), tells the child to show it only to their parent **in
  person**, and never invites sending it anywhere; a second line tells the child to refuse any other
  adult and tell a grown-up they trust. Back and Close both leave — it restricts nothing (ADR-0019).
- **Trigger** — `CommandDispatcher` handles the type (`commands/CommandDispatcher.kt`) with the
  existing `startActivity(NEW_TASK)` idiom used by `LockActivity`/`RingActivity`, so a backgrounded
  app still raises it. The manifest activity is `singleTask`, `excludeFromRecents`, `turnScreenOn`,
  and deliberately **not** `showWhenLocked` (issue #87: never cover the keyguard's PIN pad).
- **Auto-clear** — the notice stops showing the code at `expiresAt` (one-second foreground tick on
  the visible notice, no WorkManager/background timer). A withdrawal is the API clearing the payload
  (`payload = {}`): the same row arrives again on the existing 120-second redelivery and the screen
  drops to "This code is no longer valid".
- **Ack** — deliberately deferred (`CommandOutcome.Deferred`). Acking at display time would clear the
  plaintext payload server-side before the parent could read it **and** stop the redelivery that
  carries a withdrawal, so the row stays `delivered` while the notice is up and is acked `ok` with
  `detail.screen = expired|dismissed` when it ends; the dispatcher acks `withdrawn` when the API
  clears the payload. No API semantics were changed.
- **Strings** — `res/values/strings.xml` and a new `res/values-ar/strings.xml`; the Arabic copy is
  real Arabic, not a transliteration.
- **Tests** — `ResetCodePolicyTest` (20: payload parsing/validation, `1234 5678` formatting,
  inclusive expiry, remaining-minutes rounding, withdrawal vs malformed, state replacement/withdrawal),
  `ResetCodeStringsTest` (6: EN/AR key parity, Arabic characters, the "in person"/"do not send"
  instruction and the "refuse and tell a trusted adult" line) and `ResetCodeWiringTest` (5: the
  dispatcher route, the deferred ack, the background-launch gate, no payload in an intent extra, and
  the manifest's `singleTask`/`turnScreenOn`/no-`showWhenLocked` shape). All are JVM suites in
  `testPlayDebugUnitTest` / `testFullDebugUnitTest`.

**Gates (this branch, author-run):** `./gradlew testPlayDebugUnitTest testFullDebugUnitTest`
→ **590 tests per flavour, 0 failures, 0 errors, 0 skipped**, `BUILD SUCCESSFUL in 2m 23s`
(the merged-manifest gates ran, not skipped).

**Not verified in this change:** no instrumentation or hardware row was run — the notice's appearance,
background-activity launch on a real OEM, and Arabic shaping/RTL need a device and are out of scope.
The deferred-ack design also means a withdrawal can only be observed while the row is still being
redelivered (up to three attempts, roughly six minutes); after that a withdrawn code clears at its own
ten-minute expiry. If the overlay app-op and accessibility service are both off, the command is acked
`failed` with `reset_code_screen_unavailable` rather than shown.
