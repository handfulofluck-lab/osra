### Android — a restart no longer hands back used-up limits (#287, fixes #286)
- **The bypass:** every telemetry upload deletes the events it sent, and the startup rebuild replaced the
  day's counters with whatever was left in Room — at most the last upload window. A reboot, an app update,
  or Android killing the process therefore reset the per-app and daily screen-time limits for the day. A
  child could reboot on purpose.
- Measured on the Flip4 before the fix: Clock had 73 s and a 1-minute limit that had already fired at
  18:12; an update at 18:23 left Clock at 6 s (the new visit only) and My Files and Calculator gone.
- **The fix is a precedence rule, not a merge:** the saved snapshot is the day, and Room's events are only
  replayed when there is no snapshot for today. The snapshot is written on every foreground event, so the
  worst case is the single gap the process died in, capped at the 5-minute per-gap limit the counters
  already accept for screen-off.
- **The same bypass one event earlier:** an accessibility event arriving during startup could persist the
  fresh, nearly empty counters over the good snapshot. Persists now wait for the startup decision, and
  `restore` merges what was already counted instead of clearing it.
- Tests: `UsageStartupTest` pins the precedence (snapshot wins over Room, no snapshot falls back, a
  yesterday snapshot does not seed today, neither is an empty day); `UsageCountersTest` pins that a
  restored snapshot keeps the seconds an early event counted.
- **Verified on the Flip4 by Claude (2026-10-21, Full debug build, fresh family):** Clock used up a 1-minute
  `time_limit`. After the next telemetry upload and 12 s of Calculator, the agent process was killed with
  `kill -9`, and later the same build was reinstalled over itself. Both times the saved counters were
  unchanged and Clock showed "Daily limit reached" within 2 s of opening. A reboot was not run, because the
  phone's lock needs its owner after one; it starts the same fresh process.
