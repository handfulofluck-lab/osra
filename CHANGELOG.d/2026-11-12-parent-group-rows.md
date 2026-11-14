### Parent app — the iPhone's app groups, each with a Block switch (5.5 PR B3c, part 2)
- On an iPhone child's screen, under "Phone setup": the groups the phone reported, by label and counts only,
  each with a Block switch. A switch reads the stored rules and PATCHes only `appGroupRules`, changing its own
  group's rule and keeping every other (ids matched without case). A failed save shows a snackbar.
- Nothing renders for a phone that reported no groups (every Android phone).
- Five new strings in both ARBs; the Arabic is a draft pending Karim's review.
- New `app_groups_section_test.dart` (7 rows).
