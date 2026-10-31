### API — a rules version the parent can compare against what the phone applied (#475, server half)
- **What a parent will see, once all three halves land:** "The phone hasn't picked up this change yet" while
  the device's applied version is behind. This PR is the half that makes the sentence possible.
- **`RuleSet.rulesVersion`**, bumped by **every ruleset write in the same statement**, including the
  **bonus grant** (`POST /children/:childId/bonus`) — the agent reads the extra minutes from the rules
  payload, so a parent granting time while the phone is offline must see the warning too (#499 review) (`update: { …,
  rulesVersion: { increment: 1 } }`), so a saved ruleset and its version cannot disagree even if two
  parents write at once. Both `PUT` and `PATCH` carry it, and it is returned on the ruleset the agent
  fetches.
- **`Device.appliedRulesVersion`**, nullable and **never backfilled**: null is "this phone has not reported
  it", which the app renders as nothing rather than as a warning. A backfill to 0 would claim every device
  is behind on a version it was never told about.
- **The device reports it on telemetry**, beside the ADR-0034 capability report, and the server stores it
  **only when it issued it**: a version above the child's current one is logged and dropped, because a
  number from the future would clear the parent's warning on a caller bug — worse than the warning.
- **`GET /v1/family/children/:id`** returns `rulesVersion` and `appliedRulesVersion`, the latter as the
  **minimum across the child's devices**: with two handsets, one having the change is not enough.
- Migration `0030_rules_version` adds both columns; the ruleset default of 1 keeps existing rows valid.
- Rows: `rules.test.ts` (the bump is in the write statement on PUT and PATCH), `devices.test.ts` (an issued
  version is stored, a future one is not), `family.test.ts` (the minimum, and null when nothing reported).
  Mutants run: dropping the increment reddens the rules row; removing the validation reddens the telemetry
  row.
- **Not in this PR:** the agent half (keeping the applied version and sending it only after the rules are
  saved and in force) and the parent app's line. Those are the next two.
