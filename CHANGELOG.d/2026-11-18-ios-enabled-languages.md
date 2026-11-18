### OSRA Kids — a language is offered only when the family's list allows it (#883, ADR-0042 D1a)
- The iPhone child app had one idea of its languages, `["en", "ar"]`, written in three places: the app's
  `SharedLanguage`, the block screen's `ShieldText`, and the bundle check script. Public 1 adds five more
  catalogs, so those became one list the app and the extensions read together.
- `SharedLanguage` now owns the list: the compiled-in default is the released pair, the rule-sync payload may
  add `beta` languages for tester families, and the value is stored in the app group so the shield extensions
  read the same one. A language outside the list draws English, never a half-enabled screen.
- The app's own text (`L10n.tr`) now draws in the language the list allows rather than the bundle's preferred
  localization, which is what stops a compiled-in `fr.lproj` from appearing on a French phone before French is
  released. Nothing changes for a family on `en`/`ar`: the app records the language it runs in at launch, and
  that value is still the one used.
- No new string, no change to any screen. `check-app-bundle.py` reads the released list from the Swift source
  instead of keeping a second copy.
- Verified: the shared package's language rows (enabled list defaults, empty list, base language always
  present, a French phone drawing English, an enabled language used, a recorded language refused when it is no
  longer enabled, the shield making the same decision) and two rule-sync rows (the payload's list is recorded;
  a payload without it records nothing). The iPhone jobs and the real-API job are on the PR. Not verified
  where written: no iPhone screen has been photographed for this change, because no screen changed.
