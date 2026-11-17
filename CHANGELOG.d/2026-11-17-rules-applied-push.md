### Parent app + API — "the phone hasn't picked this change up yet" clears when the phone catches up (#865)
- The API publishes `rules_applied` on the family's realtime channel when the child's **lowest reported**
  `appliedRulesVersion` reaches the version the server issued (`services/api/src/routes/devices.ts`, the
  telemetry route; the reduction and the threshold live in `services/api/src/lib/rulesApplied.ts`, the same
  reduction `family.ts` uses for the child row). The frame carries the child id and the number only — no rule
  content, no device detail — and nothing is sent while another device of the child is still behind.
- It publishes on the **transition only**: `req.device` is the row before the upload, so an upload that
  repeats a version the phone already reported announces nothing — otherwise every telemetry tick would
  make every open parent app refetch the snapshot while nothing changed.
- `family.ts` now calls the same `familyAppliedVersion` instead of keeping its own copy of the reduction, so
  the number the banner shows and the number the push announces are one function.
- The parent app maps the frame to a refresh of the family snapshot (`applyRealtimeMessage`), which is the
  snapshot the banner reads, so both indicators now describe the same number. As a backstop for a dropped
  socket, the banner re-reads the snapshot when the app returns to the foreground; no polling.
- Verification: the API suite was run locally on this host, **1123 passed / 5 skipped** including five new
  route rows and four reduction rows. The Flutter side (`flutter analyze`, `flutter test`) is CI evidence —
  there is no Flutter SDK on the authoring host — and the widget rows are the two in
  `rules_behind_writers_test.dart` plus the mapping row in `realtime_refresh_test.dart`.
- Not in this PR: the wording of the banner (unchanged, so no Bureau line moves) and the iPhone
  before/after pictures (K31-Mac).
