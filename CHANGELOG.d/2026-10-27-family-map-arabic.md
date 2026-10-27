### Parent app — the family map speaks Arabic (3.1 remainder, #419)
- 18 `familyMap…` keys cover every string the map screen renders: the app-bar title, the add-geofence tooltip and
  dialog title, the marker sheet (last update plus its `unknown` fallback, battery, Ring/Lock device), the queued
  snackbars, the command failure, the empty state, and the create-geofence dialog (child label, label field,
  radius readout and slider unit, cancel/create).
- The queued snackbar no longer capitalises the command name: `Ring queued …` / `Lock queued …` are two explicit
  keys, so the Arabic reads as Arabic instead of a `toUpperCase()` applied to a translated word.
- `Cancel` reuses the existing `cancel` key and the load failure reuses `familyLoadFailed`, so `readErrorText` now
  falls back through a key like the family screen does (line 66 used to interpolate a raw English sentence).
- A new Arabic RTL row in `localization_test.dart` renders the screen at 320×568 with no overflow — the first time
  this screen's Arabic has been rendered at all. Its mutant was run: restoring the English title literal fails that
  row. Measured on this branch: `flutter analyze` — No issues found; `flutter test` — All tests passed
  (`02:53 +457: All tests passed!`).
- **Karim's review of the Arabic is the acceptance and stays open** — this adds 18 strings to that queue. The
  wording flagged for the reviewer: `رنين الجهاز` / `قفل الجهاز` (button labels, noun phrases rather than
  imperatives) and `نطاق جغرافي` for "geofence" (the rest of the app avoids the word — `alertTitleGeofence` says
  "تنبيه دخول أو مغادرة مكان").
