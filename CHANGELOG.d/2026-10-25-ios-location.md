### iOS child agent — location on the map, geofences and Locate now (5.5 PR E, #372)
- The iPhone now reports its location on the contract the Android agent already uses; the server is
  unchanged.
- **Collection:** significant-change monitoring only, with no continuous GPS and no `location` background mode.
  A suspended or terminated app is relaunched by iOS and restarts monitoring. This is coarser than Android: an
  iPhone reports when it moves a noticeable distance (`QA-IOS.md`).
- **Upload:** each fix goes to `POST /v1/location/ping` with the device token, through a 500-ping buffer in the
  app group (oldest dropped first).
  - 428 stops collection and empties the buffer.
  - 400 drops the batch.
  - 401, 429, 5xx and offline keep it.
- **Grant:** `locationGrant` (`background`, `while_in_use`, `none`) goes up in telemetry at launch, after
  pairing and on every change, so the server can refuse a `locate_now` the phone cannot answer.
- **`locate_now`** is no longer refused as unsupported. It takes a fresh fix, or one under 5 minutes old, and
  uploads it. It acks `ok` with `fix: fresh|cached` only after the server stored the point (#231). It refuses
  with Android's reasons (`location_unavailable`, `location_permission_missing`,
  `background_location_missing`).
- **Permission:** the status screen explains what the parents see and asks for When In Use, then Always. The
  usage strings are in English and Arabic; the Arabic awaits Karim's review.
- **Wake deadline:** the timer is cancelled when the drain answers first (Claude on #388).
- **Tests:**
  - `LocationTests`: 20 cases.
  - `check-app-bundle.py` checks the location strings and the absence of the `location` background mode.
  - Live case 9 places the simulator, runs a real `locate_now`, and the parent reads the point back. The live
    job now requires 9 passed, 0 skipped.
