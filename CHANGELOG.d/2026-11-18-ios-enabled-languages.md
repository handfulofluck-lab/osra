### OSRA Kids — a language is offered only when the family's list allows it (#883, ADR-0042 D1a)
- The iPhone child app had one idea of its languages, `["en", "ar"]`, written in three places: the app's
  `SharedLanguage`, the block screen's `ShieldText`, and the bundle check script. Public 1 adds five more
  catalogs, so those became one list the app and the extensions read together.
- `SharedLanguage` now owns the list: the compiled-in default is the released pair, the rule-sync payload may
  add `beta` languages for tester families, and the value is stored in the app group so the shield extensions
  read the same one. A language outside the list draws English, never a half-enabled screen.
- The app's own text (`L10n.tr`) draws in the language the list allows rather than the bundle's preferred
  localization, which is what stops a compiled-in `fr.lproj` from appearing on a French phone before French is
  released. A language the build has no table for draws English, never the phone's language.
- **The switch takes effect at the next sync, not at the next launch.** The language recorded at launch wins over
  the system list, so enabling a `beta` language now re-records it in the same step; before this, a tester family
  would have waited for a cold start.
- No new string on any OSRA screen, and nothing new for a family on `en`/`ar`: the app records the language it
  runs in at launch, and that is still the one used.
- **Known limit, stated because it is user-visible and no app can gate it:** the five catalogs also carry
  `App/<lang>.lproj/InfoPlist.strings` — the home-screen name and the two location permission prompts. iOS chooses
  those from the **phone's** language before the app runs, so a phone set to one of the five shows them in that
  language even while the family's list is still `en`/`ar` and every OSRA screen draws English. The alternative was
  not to ship those files until each language is released; that is a Bureau and UI/UX decision, not an engineering
  one, and it is raised on #883.
- `check-app-bundle.py` reads the released list from the Swift source and requires every catalog the build carries
  to be declared, so a compiled-in language cannot be invisible to iOS.
- Verified: the shared package's language rows (the list's defaults, an empty list, the base language, a French
  phone drawing English, an enabled language used, a recorded language refused once it leaves the list, the shield
  making the same decision, a newly enabled language taking effect at the next sync, an enabled tag with no catalog
  drawing English) and three rule-sync rows (the payload's list is recorded, a payload without it records nothing,
  and the default recorder is wired to the app group). Not verified where written: no iPhone screen has been
  photographed, because no screen changed.
