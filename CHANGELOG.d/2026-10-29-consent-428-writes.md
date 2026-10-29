### Parent app — a write refused for consent says why (#437 part A)
- Rule edits, the add-geofence dialog and child creation are gated by `requireConsent`, so a parent with the
  permission but a child with no active consent (or a region mismatch) saw `428 parental_consent_required` as text.
- `readErrorText` now maps both codes to a sentence that names **no command** (these are edits, not commands) and
  points at the child's *Parental consent* page, which can explain the case. A bare `428` with an unknown code keeps
  the screen's own message — the "do not invent a sentence" rule from #435.
- The English is Claude's, verbatim; **the Arabic is a placeholder pending Karim's lines**, pinned by the rows so his
  wording changes the ARB and one literal each.
- Mutant: removing the `parental_consent_required` mapping reddens the geofence row and the unit row.
- **Not in this PR:** the four `controls.ts` writes (pause/resume) still show the API's message — they go through
  `pauseInternet`/`resumeInternet` in a provider, and folding them in would widen this to a provider refactor.
