### iOS child agent — Locate now: one fix request at a time, and "fresh" means fresh (5.5, #372)
- Follow-ups from Claude's review of #390.
- **One request at a time:** a `locate_now` from an app-open drain could overlap one from a wake drain. The
  first request's 10 s timer then ended the second early, which fell back to the cached fix. The wait is now
  `OneShotFix`, with a generation per request, so a timer only ends its own request. A newer request still
  supersedes an older one that is waiting.
- **Fresh means fresh:** `requestLocation()` can answer with a fix Core Location already held. Over a minute old,
  the ack now says `fix: cached`, not `fresh`. Over five minutes, it is no answer: the cached-fix rule applies,
  else `location_unavailable`.
- **Tests:** `LocationTests` gains three cases: an earlier timer does not end a later request; a request ends on
  its own timeout; and a fix's age decides fresh, cached or no answer. Each fails with its change reverted (the
  mutant branches are named in the PR).
