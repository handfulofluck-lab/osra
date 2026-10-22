### Hardware — a missing app PIN stops the probe instead of hanging it (#151)
- Both hardware scripts declared `-Pin` as `[Parameter(Mandatory = $true)]`. On an interactive host PowerShell
  prompts for a mandatory parameter, and in a non-interactive run that prompt is not an error — it is a wait.
  A run that forgot `-Pin` therefore **hung** instead of failing, and the procedure had no way to tell the two
  apart afterwards.
- `scripts/hardware/android-bypass-probe.ps1` and `scripts/hardware/android-pairing-time.ps1` now take `-Pin`
  as optional, accept `$env:OSRA_TEST_APP_PIN` as a fallback, and **exit `2`** with a message naming the reason
  when neither is set. Exit `2` is "misused"; exit `1` stays "a check failed", so a caller can distinguish them.
  The pairing-time script requires it only for the `Machine` set: `-Human` (and `-Human -SelfTest`) needs none,
  because an observer drives it. `-DryRun` is a machine run that stops after the first pass, so it needs one.
- Verified by running both with no PIN and no environment variable: each prints the message and returns `2`.
  With `OSRA_TEST_APP_PIN` set, the bypass probe passes the guard and reaches its next step (the state-file
  read, which needs a paired phone), so the fallback works rather than merely existing.
- **Still open in #151:** item 3, the CI regression check that fails when a 4–8 digit string sits next to the
  word `PIN` in `docs/`. It needs the literal value available to CI (a repository secret), which is not
  something this change can invent; the grep in `docs/TEST-REQUESTS.md` remains the only guard. Item 1,
  rotating the test family's PIN, is the maintainer's.
