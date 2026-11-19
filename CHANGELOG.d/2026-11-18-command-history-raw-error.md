### Parent app — the device history card stops printing the raw exception (#841 follow-up)
- Ahmed's N1 on #841: `command_history_screen.dart:142` rendered the raw exception under
  «تعذّر تحميل سجل الأوامر» in the per-device history card, while the summary row above it had already been
  changed to show only the sentence. Two code paths, one fixed, which is how it survived #841's review and
  the UI/UX Bureau's frames.
- The card keeps the sentence and its Retry button and drops the detail line: there is nothing in a
  `DioException` a parent can act on.
- The `{error}` keys elsewhere on the child detail screen (`bonusFailed`, `windDownFailed`, `commandFailed`)
  are untouched — they belong to #871's batch, as the Bureau ruled.
- Verified: a new row fails a device-history request with a 500 and asserts the sentence and Retry render with
  no `DioException`/`Exception`/`bad response`/`: null`/`null`; `flutter test` in `apps/parent-app` is the
  number on the PR.
