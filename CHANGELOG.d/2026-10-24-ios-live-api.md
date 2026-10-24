### iOS child agent — tested against our real API on the macOS runner (5.5 PR A2, #372)
- New job `live-api` in `.github/workflows/ios-ci.yml`. It starts Postgres 16, Redis and the API from the
  checkout on the runner, with secrets generated for the run and masked. It seeds through the API
  (`apps/child-ios/scripts/live-api.mjs setup`: the parent logs in, adds a child with consent, mints a
  pairing code).
- The new hosted XCTest target `FamilyShieldAgentIntegrationTests` runs in the simulator app, against that
  API. It checks:
  - the claim as `platform: "ios"`, with the identity saved and read back through the Keychain;
  - a signed `screen_time_exceeded` alert → 201;
  - the same bytes again → 401 `replay`;
  - one changed byte → 401 `invalid_signature`;
  - a timestamp 600 s old → 401 `stale_timestamp`.
- `live-api.mjs verify` then checks, as the parent, that `GET /v1/alerts` holds the alert, attributed to
  the device, and that `GET /v1/devices` lists that device as `platform: "ios"`.
- Fails loudly: `OSRA_REQUIRE_LIVE=1` makes a missing input a failure, and the job requires 5 passed and
  0 skipped.
- Runs on iOS changes, on `services/api/src/routes/devices.ts`, `routes/alerts.ts` and
  `lib/internalAuth.ts`, and nightly.
- `AlertReporter` gains `makeRequest` and an awaitable `send`, which use the same request builder as
  `report`.
- Not covered: a real iPhone, the system launching the extensions, and APNs (5.1).
