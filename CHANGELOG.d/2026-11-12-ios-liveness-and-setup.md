### Parent app + API — an awake iPhone is online, and its setup report is shown (#601)

- **Two clocks gave two answers, and the app's was the wrong one.** The parent app showed a device as
  online only when `lastSeen` was under 15 minutes old (`dashboard_screen.dart:237`,
  `child_detail_screen.dart:259-261`), overriding the `status` the API had just returned. The API's own
  threshold is `DEVICE_SILENT_MINUTES` (30, clamped up in `services/api/src/jobs/deviceSilence.ts:77-113`),
  and the iOS agent reports only at launch, on app open, on an authorization change and after an app-groups
  change (`apps/child-ios/Sources/FamilyShieldAgent/Location.swift:355-359`) — so a healthy suspended iPhone
  crossed the app's window while `/v1/devices` still answered `online`. The online/offline word is now the
  API's `status`, and `lastSeen` stays as the "last seen 3 h ago" line. `kDeviceOnlineWindow` and
  `isDeviceOnline` are deleted, with `apps/parent-app/test/device_online_test.dart`, which held the rule they
  encoded.
- **The capability half was a different endpoint, not a different field.** `setupFor` already ran on
  `GET /v1/devices` (`services/api/src/routes/devices.ts:536` list, `:566` detail), but the screens read the
  devices in `GET /v1/family/me`, whose devices were `sanitizeDevice` only
  (`services/api/src/routes/family.ts:106`, before this change). `Device.setup` was therefore always null and
  `apps/parent-app/lib/features/children/phone_setup_section.dart:59` printed "This phone has not reported what
  it can do yet." (`:67` after this change) for every phone, reported or not. `/me` now attaches the same
  projection (`family.ts:110-111`), and the block keys off `setup.reportedAt`
  (`phone_setup_section.dart:61`): a current server always sends the object and puts `reportedAt: null`
  inside it, which is its "no report yet".
- **A rules fetch is a liveness signal.** `GET /v1/rules/:childId` now refreshes `lastSeen` for the device
  behind an agent token, through the poll's own throttle (`LAST_SEEN_REFRESH_MS` and the `lt` guard in
  `services/api/src/lib/pollCadence.ts`), and writes `lastSeen` only — `status` stays with the poll, the
  telemetry upload and the silence job. Parent tokens are skipped deliberately: a parent opening the
  dashboard must not make the phone look alive.
- Rows: `services/api/test/rules.test.ts` (an old `lastSeen` is rewritten by the read, a fresh one is left
  alone, a parent read writes nothing, a 428 writes nothing), `services/api/test/family.test.ts` (the `setup`
  projection on `/me`, both copies, reported and never-reported), and on the app side
  `apps/parent-app/test/device_status_test.dart` plus `widget_screens_test.dart` (online with a four-hour-old
  `lastSeen`; a stored report renders its features; `reportedAt: null` still reads as "not reported").
- **Not verified:** no phone and no live stack were used. The iOS half is read from the source, and the rules
  fetch's effect on a device row was exercised through the route with a mocked Prisma client, not against
  Postgres.
