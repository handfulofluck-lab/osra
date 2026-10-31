### Child agent (Full) — a text dated ahead is no longer imported twice when the clock comes back (#513)
- **What a parent saw.** The year-ahead SMS reached the server **twice** on the first timing of T1 (#264) and
  once on the second. Which one happened depended on whether a harvest ran while the clock was still forward —
  so the bug looked intermittent, and the second run made it look fixed.
- **Why.** A text dated inside the skew is *not* future while the clock is ahead: it is imported normally and
  moves the watermark to its date. When the clock then goes back, the clock-back branch re-anchors the watermark
  to `now` and reads nothing. The next harvest asks for `DATE > now`, the same text is now a year ahead, it was
  only ever remembered if it *was* future when it arrived — and it is imported a second time. The same hole
  covered every row with `now < DATE <= stored`, not only year-ahead ones.
- **The fix, on the phone.** The clock-back branch now asks `CommsFutureSmsPolicy.seenOnClockBack(rows, now,
  stored)`: every row the forward clock had already read is remembered in `futureSeen` **without being
  imported**, and the existing `isTracked` check keeps it out of the next harvest. `prune` drops the entries as
  the real date passes them.
- **Order matters and is pinned.** Those entries are written **before** the re-anchored watermark: a crash
  between the two costs one duplicate guard at worst, never a message.
- **No server-side dedupe**, deliberately: `Telephony.Sms` reuses `_id`, so deduping on it would drop honest
  texts — the reason the watermark is a date in the first place.
- Rows: `CommsFutureSmsPolicyTest` gains three (a row read under the forward clock is remembered; rows the
  forward clock never read are **not**, so they still arrive; and the remembered identity is the one `isTracked`
  looks for, so the two halves cannot silently disagree). `CommsClockBackWiringTest` adds two ordering rows —
  without them a policy nobody calls would keep the suite green.
- Mutants: filtering `date >= now` instead of `> now`, or dropping the `<= stored` ceiling, reddens the second
  policy row; writing `setFutureSmsSeen` after the watermark reddens the ordering row.
- **Phone row:** T1 re-runs on the emulator with **both** timings after this merges — the first timing is the one
  that reproduced it, and a single green run cannot tell the fix from the coin toss.
