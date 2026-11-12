### API — rules can block an iPhone app group by its id (5.5 PR B3a, ADR-0037)
- `RuleSet.appGroupRules`: `[{groupId, action: "block"}]`, the id the iPhone reported in `DeviceSetup.groups`.
  At most 20, one per group, strict (no label, app names or limit). A PUT without the field stores none; a
  PATCH without it keeps the stored ones. Migration `0033_app_group_rules` adds the JSONB column (default `[]`).
- Agents receive the field in every ruleset; the iPhone applying it is PR B3b, the parent app's rows B3c.
- New `rules-app-groups.test.ts` (10 rows; all fail on main).
