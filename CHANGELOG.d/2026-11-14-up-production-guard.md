### Infra — `up.sh` refuses a production run whose credential was not named (osra-security#27)
- A production run could inherit a credential the caller did not choose for it. `up.sh` now refuses, before
  it reads anything, when a run names production and `AWS_PROFILE` is unset or left at the staging default.
  The refusal names the fix rather than re-arguing the decision.
- `scripts/check-up-production-guard.mjs` runs the real script with a controlled environment (four checks)
  and its self-test removes the guard from a copy and shows check 1 stop passing. Wired into
  `workflow-lint`, because a guard no job runs is the shape this repository keeps finding.
