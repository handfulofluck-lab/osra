### Parent app — a tamper alert says what happened (#443 / #453 follow-up)
- A `tamper` alert used to show only "Protection tampered with". Its title now comes from `metadata.type`:
  "An app got around the block" for `block_bypass` (#443, #449), and "OSRA's data was cleared on a phone"
  for `agent_data_cleared` (#453). Other types keep the generic tamper title.
- The alerts feed, the alert dialog and the child's alert list use the new titles. The lock-screen
  notification stays generic, as #360 decided.
- The two Arabic lines are drafts for Karim. A new `localization_test` row pins both English titles, the
  fallback, and that the type is ignored outside `tamper`.
- `tamper_title_tile_test.dart` pumps `AlertTile` with a `block_bypass` alert, so dropping the type at that call
  site turns a test red.
