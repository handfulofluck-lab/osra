### iOS — a UI-test target, so the escape rows that need no device can finally run (#739)
- The child agent had no UI-testing target at all: `project.yml` declared only unit-test bundles, no
  `XCUIApplication` appeared anywhere in the tree, and `ios-ci.yml` had no step that drove the app's screens.
  Every escape row in the catalogue was therefore either hand-run or not run.
- `OSRAAgentUITests` and its `OSRAAgentUI` scheme are added, with one smoke case that launches the app on the
  simulator, finds the pairing screen by the app's own accessibility identifiers, types six digits and asserts the
  pair button only then becomes enabled. It runs inside the existing `test-ios` job — same runner, same simulator,
  same triggers and concurrency group — so no new job, schedule or path filter.
- The test target links the app's Swift package so it asserts the same `A11yID` constants the app sets, rather
  than a second copy that a rename could silently desynchronise.
- **KP01 is the only catalogue row this can cover here.** KS03, KX01 and KO01 need a device in Family Controls
  `.child` authorisation and stay device rows; the catalogue's own schedule says so. KP01's rule half already runs
  in `ParentPinTests`; this target is for its screen half, which needs the seeded-identity launch argument Claude
  and Ahmed are reviewing and which is not in this change.
- The gate's mutant: delete `pair.code` from `PairingView`'s accessibility identifier and the smoke case fails at
  its first assertion, so the row is not vacuous.
- Verified locally: `scripts/check-identifiers.py` reports 0 problems with the new target's bundle id, and the
  workflow parses with the same four triggers. **Not verified:** the UI test itself has never run — there is no
  Xcode on this PC, so the first execution is CI, and the PR says so.
