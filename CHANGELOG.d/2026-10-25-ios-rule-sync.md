### iOS child agent — the parent's rules reach the iPhone (5.5 PR C, #372)
- `RuleSyncer.syncNow()` runs when the app opens and after pairing. It fetches `GET /v1/rules/:childId` with the
  device token, the Android agent's contract, and decodes it into `RuleSet`, which ignores fields it doesn't use.
- `RuleStore` writes the rules into the app group, where the monitor and shield extensions read them:
  - the blocked apps (`apps.blockedBundleIdentifiers`, `bedtime.blockedBundleIdentifiers`);
  - the bedtime window, blocked domains and categories;
  - the routines.
- Days convert from the rules' 1=Mon..7=Sun to Foundation's 1=Sun..7=Sat (`ruleDay % 7 + 1`); an out-of-range
  day is dropped.
- `ScreenTimeController.applyRules` enforces blocked apps, the web filter, bedtime, and each routine once per
  weekday (an overnight routine ends the next day). The monitor shields a routine's own apps.
- A 428 (consent withdrawn) clears every stored rule and shield. Other failures keep the last rules. Unpairing
  clears them.
- At launch, Keychain secrets that no identity owns, left by a previous install, are deleted. A paired phone is
  never touched. Claude raised this on #378.
- Tests:
  - `RuleSyncTests`: the weekday table, the server shape, the stored keys, the routine lookup, and sync
    outcomes 200 / 428 / 500 / not paired;
  - orphan clean-up in `AgentIdentityStoreTests` and the hosted `KeychainTests`;
  - live case 6, where the rules the parent set through the API sync with the device token. The job now
    requires 6 passed and 0 skipped.
- Not yet: the shields appearing on a real phone (5.1), and the on-device category picker.
