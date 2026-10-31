### iOS agent — reports the rules version it actually applied (#475, iOS half)
- `RuleSyncer.syncNow` records the rule set's `rulesVersion` (1 when an older server sends none) only after
  `ScreenTimeController.applyRules` returns without throwing, and sends it at once on
  `POST /v1/devices/:id/telemetry {"appliedRulesVersion"}`. `applyRules` now throws `notAuthorized` without
  Screen Time authorization and `unscheduled` when a bedtime or routine activity was refused; either keeps
  the old applied version, so the parent's "not picked up yet" line stays up.
- Every telemetry upload carries the stored version; before the first apply the field is left out, never
  sent as 0. A consent withdrawal (428) clears it with the rules.
- Rows: five in `RuleSyncTests`, and live case 10 (`test9b…`) with `live-api.mjs verify` reading
  `appliedRulesVersion == rulesVersion` back as the parent.
