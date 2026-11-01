### API — a per-app daily limit is capped at a day (#508 review)
- `AppRuleSchema.dailyLimitMinutes` is capped at 1440 (was 10080), the same one-day cap #508 put on the two
  screen-time limits. The parent app's per-app limit is a text field, not a `Slider`, so no screen can crash
  on a stored value outside a range; a value above 1440 is now refused on save.
- Row in `rules.test.ts`: 1441 refused with 400, 1440 accepted.
