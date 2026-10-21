### Android — per-app time limits fire: the usage counter keeps milliseconds (#281, fixes #276)
- **Measured on the Flip4:** the status bar sends an accessibility event every minute, so the gap between
  two foreground events is ~59.9 s. `UsageCounters` floored **each gap** to whole minutes (`gapMs / 60_000`),
  every gap became 0, and the counter never reached 1 — a per-app `time_limit` never fired. Blocking
  (`action: "block"`) was never affected. Found by Claude on the Flip4.
- The floor lived in two places and both are gone: `UsageCounters.onForegroundEvent`, the counter the
  enforcement decision reads, and `computePerAppMinutes` in the telemetry path, which lost the same
  seconds from the parent's screen-time total.
- Usage is now accumulated as milliseconds and converted once. The 5-minute screen-off heuristic is still
  a **per-gap** cap, just in ms. Each package's sub-minute remainder (`usage_remainder_ms`) is carried into
  the next upload window and written in the same success step as the watermark, so fifteen 59 s windows no
  longer lose a minute each: two consecutive windows sum to the same total as one window covering both.
  A re-grant drops the carry with the events it belongs to (#266's rule).
- **The persisted snapshot survives a version change:** it now carries a unit marker, so an old
  minutes-valued snapshot is read as `minutes × 60_000` instead of being divided by 60.
- **A restart still loses the day's counters, for another reason:** the startup rebuild replaces the
  snapshot with the events since the last upload (#286, found on the same phone run — rebooting the phone
  likewise hands back used-up limits). Older code, filed rather than folded in here.
- **Time on OSRA's own block screen is credited to the blocked app** (#284), also found on the same run
  and also filed separately.
- **The UsageStats backfill no longer double-counts short use** (review R1). It skips a package the
  window's events mentioned even when that package produced no whole minute, because its time is counted
  here — as a minute now or as a carried remainder next window. An app used in 30-second bursts was
  reported at about 1.5× its real time, which is the number the parent reads. A package carrying only a
  remainder is still backfilled: the previous upload's snapshot already covered that time.
- Tests: `UsageCountersTest` (59.9 s cadence reads 10 minutes, a 1-minute `time_limit` is reached from
  sub-minute gaps, the 20-minute gap still caps at 5, an old minutes snapshot restores to 45) and
  `UsageAggregationTest` (16 events 59.9 s apart read 15 with the remainder carried, two windows equal
  one, a sub-minute event package is "mentioned" while a carried-only package is not).
  `./gradlew testPlayDebugUnitTest testFullDebugUnitTest` green, 546 tests each flavour.
- **Verified on the Flip4 by Claude (2026-10-21, Full debug build, fresh family):** Clock with a 1-minute
  `time_limit` showed "Daily limit reached" 68.9 s after it opened, at the first status-bar event past 60 s.
  Calculator used for 2 min 24 s uploaded as 2 minutes from events, with 24 s carried. A further 30 s of
  Calculator uploaded nothing and grew the carry to 54 s.
