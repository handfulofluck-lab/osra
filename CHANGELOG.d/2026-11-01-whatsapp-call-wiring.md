### Child agent (Full) — a WhatsApp call is wired end to end: one row per call, never content (#4.5, wiring)
- **What a parent sees now:** a WhatsApp call appears once in the Calls & SMS timeline with the caller's name,
  "WhatsApp" under it, and the time. An answered call also carries `≈ mm:ss`; a missed call carries none; a call
  that ended without ever being answered carries neither a direction nor a length.
- **The parser from #523 is unchanged in what it decides; this PR is the order the facts arrive in.**
  `WhatsAppCallTracker` (pure, JVM-tested) holds one row per call across the three notifications the phone
  actually sends: the ring, the change when it is answered, and the removal.
- **"Answered" is measured, not guessed.** A change on the same notification key with the importance falling
  (4 → 2 in the capture) **or** the channel moving from the `voip_notification` prefix to
  `silent_notifications` prefix marks the call answered, and only an answered call gets a duration. The channel
  is matched on its **prefix**: the capture's suffixes (`_4`, `_3`, `_1`) are numeric and move between calls.
  `FLAG_FOREGROUND_SERVICE` is deliberately not a signal — the capture's outgoing call carried it from its first
  row.
- **An ignored call is one row.** Its removal is held for up to 5 s for the `missed_call` notice, which arrives
  on a **different** notification id (23 vs 4) about 1.2 s later, so the two are paired on package and timing
  and never on key. Without the hold, an ignored ring became a missed row plus a phantom "ended" row.
- **A call that was never answered and never notified still gets a row.** Claude's capture caught the gap: the
  outgoing call was posted on `voip_notification_4` and removed 25 s later with no change and no notice, so
  before this PR the child's outgoing calls left no row at all. The row is `unknown` direction with **no
  duration** — `0` would say the call connected and ended instantly, and the elapsed time would claim it
  connected at all.
- **No user filter.** The notification key already carries the Android user (`0|com.whatsapp|23|null|10406`), so
  a call to the Dual-Messenger clone in user 95 produces a row exactly like a call to the main profile. The
  capture had no user-95 traffic, so this is pinned by a fixture, not yet observed on the phone.
- **The body still cannot reach the row.** The call snapshot carries category, title, importance and channel —
  no text, no big text, no messaging lines — so the call path cannot carry content even by accident.
- **The row is durable and typed.** `CommsEventEntity` gains `source` and `durationApprox`, and its `durationSec`
  becomes nullable (Room 3 → 4, a table rebuild around the same rows so a queued upload survives the upgrade).
  A null duration is **omitted** from the wire rather than sent as `0`; `CommsPayloadPolicy` is the pure mapper
  that does it, so `CommsLogger` is a one-line caller and the absence is a unit test.
- **Consent still gates everything:** the pause is checked before the notification is read and again before the
  row is written, and the listener keeps recording nothing while revoked (ADR-0008 §3).
- Rows: `WhatsAppCallTrackerTest` (9) — the capture's three calls replayed: answered (one row, 39 s, `≈`),
  missed (one row, no duration, paired across ids), outgoing (one unknown row, no duration, once), plus user 95,
  prefix-only answering, a no-op re-post, the deadline, another package's notice, and one identity. Plus 3 new
  rows in `WhatsAppCallPolicyTest` and 4 in `CommsCallPayloadTest`.
- **Not verified here, and named so a green suite is not read as more:** delivery to our own listener on real
  silicon (the capture ran with the agent uninstalled), a call to the user-95 clone, and whether a *connected
  outgoing* call ever changes channel. Those three are owed on the Flip4 before the row moves to ✅.
