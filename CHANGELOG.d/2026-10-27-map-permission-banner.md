### Parent app — the map and the child card say when a read is refused (#406, decision 7)
- `anyReadRefused(values)` joins `readErrorText` in `api/permission_errors.dart`: loading and data are never a
  refusal, a plain 500 is not a refusal, and only `ReadPermissionRequired.isRefusal` counts.
- The family map shows **one** banner over the map — `topCenter` inside a `SafeArea` — when any child's location or
  geofence read is refused. The permission belongs to the guardian, not to a child, so there is one notice and not one
  per child; the map, its markers and the long-press are unchanged, and other errors keep today's silent behaviour.
- The dashboard's child card stops reading a refusal as "No location yet" and names the owner instead.
- No new strings: both reuse `readPermissionRequired`, so nothing new goes to Karim for the Arabic.
- Tests: four helper rows, and a dashboard widget row that overrides `locationProvider` to throw the server's refusal.
  The map itself is not widget-tested — `GoogleMap` is unavailable in the test environment, which the note above
  `fitCameraToChildren` already records.
