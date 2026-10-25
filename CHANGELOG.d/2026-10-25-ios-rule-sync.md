### iOS child agent — the parent's rules reach the iPhone (5.5 PR C, #372)
- `RuleSyncer.syncNow()` runs when the app opens and after pairing, and only then (PR D brings `rules_updated`). It
  fetches `GET /v1/rules/:childId` with the device token, the Android agent's contract, and decodes it into
  `RuleSet`, which ignores fields it doesn't use.
- `RuleStore` writes the rules into the app group, where the monitor and shield extensions read them:
  - the blocked, allowed and always-allowed apps;
  - the bedtime window, blocked domains and categories;
  - the routines.
- Days convert from the rules' 1=Mon..7=Sun to Foundation's 1=Sun..7=Sat (`ruleDay % 7 + 1`); an out-of-range
  day is dropped.
- What a running interval shields is a pure function, `ShieldPolicy.decide`, following Android's `RuleEngine`:
  - bedtime, and a routine with `allowedApps`, shield everything except the allowed apps and the dialer
    (`.all(except:)`);
  - a block-list routine shields its own apps;
  - a routine shields nothing on a day it doesn't run.
- Each routine is one daily activity (`routine.<index>`), with the weekday checked when it starts, so a seven-day
  routine can't hit the per-app activity cap. Refused activities are recorded and logged once.
- Before monitoring stops (stale routines, or a 428), each activity's named store is cleared, so a running
  interval's shield can't be left on.
- A 428 (consent withdrawn) clears every stored rule and shield. A 401 and any other failure keep the last rules,
  as Android does. Unpairing clears them.
- At launch, Keychain secrets that no identity owns, left by a previous install, are deleted. A paired phone is
  never touched. Claude raised this on #378.
- Tests:
  - `RuleSyncTests`: the weekday table, the server shape, the stored keys, the `ShieldPolicy` rows, one
    activity per routine, clear-before-stop, and sync outcomes 200 / 428 / 500 / not paired;
  - orphan clean-up in `AgentIdentityStoreTests` and the hosted `KeychainTests`;
  - live case 6, where the rules the parent set through the API sync with the device token. The job now
    requires 6 passed and 0 skipped.
- Not yet: the shields appearing on a real phone (5.1), and the on-device category picker.
