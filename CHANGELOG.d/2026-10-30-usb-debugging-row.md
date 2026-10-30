### Child agent — onboarding warns while USB debugging is on (#81 step 2)
- A new recommended row, "USB debugging off", sits after Battery in the onboarding checklist. While USB
  debugging is on it says that anyone with a computer can clear OSRA's data on the phone, and its button
  opens Developer options. It does not block pairing, because families turn debugging on for real reasons.
- It reads `Settings.Global.ADB_ENABLED`, which needs no permission; an unreadable value counts as off.
- ADR-0010 now records why plain device admin cannot block `pm clear`: only a device owner can set
  `DISALLOW_DEBUGGING_FEATURES`. That is #81 step 3, and it stays a note.
- `OnboardingPolicyTest`: two new rows (recommended and placed after Battery; the three `ADB_ENABLED` values).
