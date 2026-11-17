### Parent app — "Where does your family live?" instead of "Jurisdiction" (R-ID-4, #650)
- The consent picker on **Add your child** (`setup_child_screen.dart`) and on the dashboard's add-child
  dialog now asks "Where does your family live?" — the label moves behind the existing
  `jurisdictionLabel` key, so no call site changed and no second copy of the question appeared.
- The picker already preselects the family's own region from `GET /v1/family/me`
  (`authProvider.family.region`) rather than a fixed United States; four new rows in
  `rid_family_region_test.dart` pin the label, the preselection for EU, UK and US, and that no code
  (`EU`, `UK`) is ever rendered.
- **Arabic is not updated in this commit.** The Bureau's line for the new English wording is requested on
  #604; the Arabic key still carries the old phrase until it is issued, and I will not author it. That
  mismatch is the reason this PR needs `needs:arabic` and cannot merge without the Bureau's line.
- Not in this scope, raised for the Bureau: `consent_screen.dart:172` renders
  `consentStateMismatchDetail(record.jurisdiction, family.region)`, which puts the raw codes in a
  sentence. That is a separate string change and belongs with the wording batch.
