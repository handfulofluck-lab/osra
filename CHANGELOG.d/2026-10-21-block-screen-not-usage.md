### Android — time on OSRA's own block screen is no longer charged to the blocked app (#288, fixes #284)
- **The measurement:** on the Flip4, 103 s on a bedtime block screen ("This app is blocked by your
  parent") charged My Files 103 s, and a 1-minute limit then fired **0.9 s** after the app was opened
  again — on time it had never been used. The second stay, 123 s, was charged the same way.
- **The cause:** both counters credit each recorded event with the time until the *next* one, and
  `AccessibilityMonitorService` deliberately drops OSRA's own package (deciding from it is how the
  overlay ended up over the launcher, #165). Our overlay therefore never closed the blocked app's
  interval, and the next event — Home, another app — closed it with the whole stay, capped at the
  existing 5-minute per-gap limit.
- **What the two counters do now:** the accessibility service tells `UsageReporter` when our own window
  is in front; `UsageCounters` credits the open gap so far and closes it, so nothing is in progress, and
  `UsageReporter` writes an own-package event so the upload path ends the previous app's gap too.
  `computePerAppMinutes` credits neither the own window's gap nor the own package's own time, and the
  UsageStats backfill skips that package by name — Android counts the block screen as foreground time,
  and that is not the child's use either.
- **What a family sees:** bedtime and school hours no longer spend the daily limit while the child
  reads the block screen, and a child waiting on "Request access" no longer spends the granted bonus
  before the parent has answered. The parent's screen-time report no longer shows minutes in an app the
  child could not open.
- **⚠️ not verified here:** the handset row — a bedtime block screen left up for two minutes adds
  nothing to the blocked app, and the parent's report stays flat — is the reviewer's.
