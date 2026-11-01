### Parent app — "the phone hasn't picked this change up yet" follows every screen that writes rules (#475 follow-up)
- **Where it shows now.** The line used to live on the rule editor only. It now also sits on the **social
  screen** (monitoring toggles and the contact allowlist both write rules) and on the **bonus-time card**,
  because a grant posts `/v1/controls/children/:id/bonus` and that bumps `rulesVersion` (`controls.ts:88`).
- **One widget, not three.** `RulesBehindBanner` was a block inside the editor; it is a `ConsumerWidget` now —
  same key, same `rulesBehindHint`, same family overview the app already loads, and it collapses to a
  zero-height box when the child is current or unknown, so a screen can place it unconditionally. The editor
  uses it, which is why its nine existing rows needed no change.
- **Every rule writer now refetches the family snapshot.** `alerts_screen` (blocking an install-request app),
  `social_screen` (both saves) and the bonus grant invalidated only `rulesProvider`, so right after the write
  the app believed `applied == rules` and the line could not appear at the moment it was earned — the #501
  review finding, on the screens that were not covered.
- **The line lives in `SocialSectionsView`, not in the `SocialScreen` wrapper** (Claude, #522): the child-detail
  Social tab renders that view directly, so the wrapper-only version left the tab — which writes the same toggles
  and allowlist — showing nothing after a save.
- Rows: `rules_behind_writers_test.dart` (10) — behind shows the line, current shows nothing, never-reported
  shows nothing, on the social screen and on the bonus card; the child-detail Social tab shows it too; and three
  save rows: the monitoring toggles, the contact allowlist, and the bonus grant, each bumping the version in the
  fake and expecting the line only because its write refetched the family.
- Mutants: `<=` instead of `<` in `rulesAreBehind` reddens the "current shows nothing" row alone (1 of 3);
  dropping the `familyProvider` invalidation from `_grant` reddens the grant row alone (1 of 7).
- **Not in this PR:** no banner on `alerts_screen`. It is a family-wide feed with no `childId`, so a per-child
  line there would name no child; its refresh is in, and where the line belongs on that screen is an open call.
  That screen also has no test file today, so its first row would also be its first harness.
