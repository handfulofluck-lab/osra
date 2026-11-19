### Parent app — three label/semantics blockers on the app picker (#872, Antigravity's review at `fb8717f4`)
- **The remove action's labels were unpinned.** Stripping all three `deleteButtonTooltipMessage`/`tooltip`
  calls left 83/83 green. A row now reads the label off the always-allowed chip in both states — absent and
  pending — so the mutant dies.
- **A rule with a real saved name drew a "?" avatar and announced "Name not available yet".** The avatar was
  built from the report alone; `appDisplayAvatar` now takes the saved name and shows its first letter, and the
  remove tooltip is only the state's label when the row has no real name to announce.
- **One `404` from a `pending` sibling emptied the whole inventory**, hiding the first phone's names behind the
  pending line; the merged provider now catches `404` per device, as the per-device one already did. And
  **a truncated report counted as "complete"**, so an app missing from a cut-short list read as uninstalled:
  `_reportIsComplete` now requires every device to have reported and no report to be truncated.
- Verified: four rows in `installed_apps_picker_test.dart`, one per finding, each naming its mutant;
  `flutter test` in `apps/parent-app` is 1008 passed.
