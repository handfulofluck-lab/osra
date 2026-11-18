### Parent app — site names readable in full, and the reports chart at 320 px / 200 % (#841 Bureaus)
- **Site-name rows are no longer truncated (#841 condition 2, UI/UX and Arabic Bureaus).** `_SiteTile` drew
  the host with `maxLines: 1, overflow: ellipsis`, which cut the one thing the row exists for — in the Arabic
  app the cut landed on the left edge, so the reader saw the start of the name marked as missing. The row now
  draws the host in full, left-to-right isolated, with a zero-width space after every dot
  (`ltrIsolateHost`, `apps/parent-app/lib/core/ltr_isolate.dart`) so the line breaker prefers a dot before it
  breaks inside a label. No `maxLines`, no ellipsis. At 320 px with 200 % text the row grows; the Bureau's
  three-line allowance holds in the real font, and a widget test asserts what the requirement actually is —
  that nothing is cut (`RenderParagraph.didExceedMaxLines == false`).
- **The blocked-domain row keeps the host whole too** (#841 condition 2 applied where condition 5 touches the
  same row): same isolate and break points, so the two rows in the web card read alike.
- **The reports chart sizes itself to the text scale (#841 condition 4).** `reports_screen.dart` now draws
  `TopAppsChart`: the value axis uses an interval that yields **at most three** labels instead of whatever
  the library picked; the axis reserves the width the widest label **measures** at the current text scale
  (`TopAppsChart.axisWidthFor`) instead of a fixed 64 px; the chart's height grows with the label strip; and
  each app label gets its own slot to wrap into, instead of being cut to eight characters with an ellipsis.
- **The blocked count moves under the host at narrow widths and large text (#841 condition 5).** At a width
  under 360 px or a text scale above 130 %, `blockedTimes` is the row's subtitle rather than a trailing column,
  so it stops competing with the host for the same pixels. The wide layout the Bureau already reviewed is
  unchanged, and a widget test pins both directions.
- **Tests:** `apps/parent-app/test/reports_narrow_text_test.dart` (new, 7 rows: three-tick axis, full app name,
  axis width at 100 % vs 200 %, no overflow at 320/200 %, count stacked at 320/200 %, host isolated, count
  still trailing at 800/100 %) and three new rows in `test/usage_history_test.dart` plus two in
  `test/ltr_isolates_test.dart`. Each row names the mutant it catches.
- **Verified on this host, which does have Flutter:** `flutter pub get`, `flutter analyze lib/features/reports
  lib/core/ltr_isolate.dart` → no issues, and `flutter test` in `apps/parent-app` → the whole suite green
  (Flutter 3.47.9 / Dart 3.13.7, `C:\KARIM\tools\flutter\bin`). The previous fragment on this branch said no
  Flutter SDK was available here; that was true of the earlier session and is not true of this one.
- **Not in this change:** condition 1 (raw error text) still waits on #871, per the coordinator's order.
