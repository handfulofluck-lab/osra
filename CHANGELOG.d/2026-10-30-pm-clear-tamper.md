### Child agent, API and parent app — a `pm clear` wipe is named, not just silence (#81 step 1)
- `adb shell pm clear` wipes the agent despite device admin, and the wipe takes the device token with it,
  so the phone can't report the wipe when it happens. The parent's first signal stays `device_silent`.
- What the wipe leaves behind is recognisable: device admin is still active, but there is no pairing and
  no parent PIN. A fresh install has no admin, and the parent's Re-pair keeps the PIN.
  `WipeDetector` spots this state; the pairing form then says the phone's OSRA data was cleared, and the
  next pairing claim carries `dataCleared: true`.
- The parent's Allow/Deny card shows "OSRA's data was cleared on this phone…". Allowing it records one
  `tamper` alert with `metadata.type = agent_data_cleared` (dedupe key: the claim). Deny records nothing.
  The flag adds no new unauthenticated surface: a claim still needs a live parent code.
- Tests: `WipeDetectorTest` (4 states), two vitest rows in `pairing.test.ts`, and a widget row in
  `pairing_qr_test.dart`. The new Arabic line on the parent card and the agent's notice are drafts for
  Karim; the agent's notice is English-only until then.
