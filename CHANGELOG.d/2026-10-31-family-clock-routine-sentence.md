### Parent app — the "Blocked now by …" sentence is read on the family's clock (#476)
- The child's phone enforces routines in its own zone, but the parent app checked the window on the
  parent's clock, so a parent travelling in another zone saw the wrong window.
- `GET /v1/family/me` now carries `family.utcOffsetMinutes`, the family zone's offset at the moment of the
  request, computed with `Intl` from the stored `timezone` (`utcOffsetMinutes` in `lib/digestSchedule.ts`).
  It is absent while no zone has been set (`timezoneSource = default`).
- The parent app shifts `clockProvider`'s instant by that offset (`familyWallClock`) before it checks a
  routine, bedtime or school-hours window, and keeps its own clock when the field is absent. No tz
  database ships in the app.
- Rows: two API rows (Dubai → 240, no zone → no field) plus a DST/sign/sub-second row for the helper;
  a unit row for `familyWallClock` and three widget rows in `routine_override_test.dart`.
