### Child agent — report the rules version it SAVED AND APPLIED, not the one it fetched (#475, agent half)
- **The ordering is the feature.** `RuleRepository.refresh` now stores `appliedRulesVersion` **after**
  `saveRulesJson`, and **only if that write succeeded**. A version stored at fetch time would tell the parent
  the phone has a change while the previous rules are still in force — the warning would clear on exactly the
  state it exists to catch.
- `RuleSetDto.rulesVersion` (default 1, so an older server still parses) is the value the server bumps on
  every rule write.
- Every telemetry upload carries it — the periodic one and the grant report — as `appliedRulesVersion`,
  omitted when this install has never applied a ruleset (a fresh phone reports nothing, which the server
  stores as null and the parent renders as no warning).
- `AgentSettings` gains `saveAppliedRulesVersion` / `appliedRulesVersion`; the value survives a restart, so a
  phone that applied version 7 yesterday reports 7 before its first refresh today.
- **The version is dropped when its rules are** (#500 review): `forgetRules()` removes it beside the cached
  ruleset, and `clearPairing()` removes it on a re-pair while keeping the rules a same-family re-pair still
  enforces. Left behind, a phone re-paired to another child would report the previous child's number, and
  because the server stores any version not above the one it issued, the parent would read "not received
  yet" for a change this phone never had — a false warning pointing the wrong way.
- Rows: `AppliedRulesVersionWiringTest` (5) — the save order, the one writer, the persisted guard, the DTO
  field, both upload paths, and the two reset paths (each scoped to its own function body, so `forgetRules`
  cannot satisfy the `clearPairing` row). Mutants run: dropping the `if (persisted)` guard reddens the
  ordering row; dropping the field from one upload path reddens the "every upload carries it" row; removing
  either `it.remove(KEY_APPLIED_RULES_VERSION)` reddens its own reset row and nothing else.
- **Also in this PR, as you asked:** the two stale `[RuleEngine.windowFor]` KDoc references from #496
  (`WindowReason.kt` and `RuleEngineWindowReasonTest.kt`) now name `evaluateWithReason`.
- **Not in it:** the parent app's "hasn't picked this up yet" line and its Arabic — that is PR 3.
