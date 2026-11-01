### Parent app — the "not picked up yet" line in the alert dialog, scoped to that alert's child (#475 follow-up)
- **Where it shows.** The alerts **feed** is family-wide, so it carries no line. The **detail dialog** is about one
  alert's child, so that is where a parent who opens an alert later learns whether their last change landed —
  `RulesBehindBanner(childId: alert.childId)` as the first child of the dialog's content.
- **No new strings:** the same `rulesBehindHint` Karim approved in English and Arabic, read inside the dialog
  from the family overview the app already loads. The Block path already refetches that overview.
- **Rows:** `alerts_dialog_test.dart` (3) — this is the alerts screen's first widget test. A dialog for a child
  whose phone is behind shows the line; a current child's does not; and with two children where only one is
  behind, the line appears on that child's alert and not on the other's.
- Mutants: removing the banner reddens the behind row and the two-child row (the "current shows nothing" row
  correctly stays green); keying it to `child-1` instead of `alert.childId` reddens **only** the two-child row,
  which is why that row exists.
- **Harness note:** an unmapped alert category renders the server title verbatim (`alertTitleFor` falls back to
  it), so each alert in the test is findable by its own title; a mapped one renders "App blocked" for both and
  the two-child row could not tell them apart.
