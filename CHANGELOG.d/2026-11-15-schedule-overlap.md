### API — typed bedtime and school-hours overlap errors (#803, #642)
- A real bedtime/school-hours collision now returns `schedule_overlap` with both windows and school days, not an instruction to set `allowOverlap` in the request.
- Overnight bedtimes that do not meet school hours save normally. Weekend daytime collisions are still refused, while `days: []` means no school days and is accepted. Existing `allowOverlap` compatibility is preserved.
- This is the API-only slice. The parent-facing message is tracked separately in #801; no user-facing text changed here.
