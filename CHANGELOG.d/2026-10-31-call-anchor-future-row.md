### Child agent — a call made during a withdrawal with the clock set forward is never uploaded (#264)
- **Claude's sweep found the hole I missed** when I reported #264 as delivered: the withdrawal half. A call
  made while consent was withdrawn **and** the clock set forward has a future `DATE`, so the anchor
  (`newestCallIdEndedBy`, "ended by the ceiling") landed below its `_ID`; after the re-grant the read
  `_ID > anchor` reached it and `shouldReadCall` answered yes, because a future row is `>= floor`. A
  withdrawal-window call reached the parent — ADR-0008 forbids exactly that. `isClockBack` had the same hole.
- **The rule is now one pure function**, `CommsWatermarkPolicy.countsAsBeforeAnchor(rowDate, durationSec,
  ceiling, now)`: a row counts as **before** the anchor when it ended by the ceiling **or** when its `DATE`
  is later than the real `now` + the five-minute skew. A row dated beyond that cannot be a genuine
  post-grant call, so the anchor moves above it. Ids are monotonic, so every real post-grant call stays
  above the anchor, and the #257 row ("the call that triggered the harvest survives") still holds.
- The anchor query now selects both shapes (ended by the ceiling, or future-dated) and lets the predicate
  decide, so one SQL change cannot widen what is anchored without a row going red.
- Rows (`CommsWatermarkPolicyTest`): a future-dated withdrawal call is anchored past and not read; a real
  call after the re-grant is still read; the `isClockBack` case. Mutant: remove the `rowDate > now + skew`
  clause and the first and third rows go red.
- `CommsGrantWiringTest` was updated to assert the policy call rather than the inline `endedAt <= ceilingEnd`,
  and its "no DATE predicate" assertion became the positive "the read is `_ID > ?`" — the anchor query may
  legitimately use `DATE` now, and a negative on the whole file would have been a false guarantee.
- **Not in it:** the Flip4 row (T1 on #484, Full build: inject a future-dated withdrawal call, re-grant, and
  see nothing uploaded). That is Claude's queue.
