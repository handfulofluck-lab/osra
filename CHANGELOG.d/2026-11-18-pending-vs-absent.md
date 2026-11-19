### Parent app — "no report yet" and "no longer installed" are different sentences (#872, Codex's finding)
- Codex caught a real conflation in the first pass of condition 2: one fallback line covered both "a device
  reported its app list and this id is not in it" (**confirmed absent**) and "no device has reported yet"
  (**pending**). Saying «تطبيق لم يعد مثبّتًا» before any report claims something nothing has supported.
- `appDisplayName` now takes `reportKnown` (a report exists and carries a `reportedAt`). Confirmed absence
  keeps the Bureaus' `appNoLongerInstalled`; the pending state uses the second line they issued,
  `appNamePending` — "Name not available yet" / «الاسم غير متوفّر بعد» — and the name fills in by itself when
  the report arrives, so no extra hint line is needed.
- The remove action carries a matching screen-reader label and tooltip: `appNoLongerInstalledRemove` /
  `appNamePendingRemove`, on the always-allowed chip, the app-rule row and the routine chips. That closes the
  second half of Codex's note — the semantics were issued but unattached.
- Verified: a new row gives the screen a report with `reportedAt: null` and asserts "Name not available yet"
  appears while "App no longer installed" does not; `flutter test` in `apps/parent-app` is 1004 passed.
