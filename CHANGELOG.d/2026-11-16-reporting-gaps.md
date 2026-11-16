### Android reporting — what the parent sees after a session of blocked attempts (#830)
- On the Flip4 (15 Nov) every attempt was blocked on the phone, but the parent's data was nearly empty:
  no alerts, 22 minutes with no per-app breakdown, and nothing in the web or activity reports.
- **Usage:** the agent sent `perAppMinutes` while the server read `appUsage`, and `/telemetry` then wrote
  only the `"*"` device total. The agent now sends the `appUsage` contract, the server records per-app
  `AppUsageDaily` rows (and still accepts the old map for one release), so `/reports/usage` fills `apps`.
- **Alerts:** every block posts a grouped `app_blocked` row (`app:<pkg>:<utc-day>`, monotonic attempt
  count), not only the "Request access" tap; every blocked DNS sink posts a grouped `web_threat` row
  (`domain:<host>:<utc-day>`) at most once per host per ten minutes.
- **Lock:** a lock period records start, mode and the number of overlay raises, and is posted as one
  `lock_period` activity row when the parent unlocks; a period left open by a process death is reported
  without an end time rather than dropped. The server accepts the new activity type.
- **Web report on Play:** it stays empty for beta A (Claude's decision on #830), with an honest empty
  state in the parent app so silence is not read as "nothing happened". Parent strings go through both
  Language Bureaus.
- Tests: the API rows pin the `appUsage` contract and the legacy map; JVM rows pin the dedupe keys, the
  site quiet window, the lock payload and the four call sites.
