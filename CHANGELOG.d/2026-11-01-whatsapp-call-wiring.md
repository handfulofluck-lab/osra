### Child agent (Full) — a WhatsApp call is wired end to end: one row per call, never content (#4.5, wiring)
- **What a parent sees now:** a WhatsApp call appears **once** in the Calls & SMS timeline, with the caller's name
  and "WhatsApp" under it, and the time it rang. An answered call also carries `≈ mm:ss`; a missed call carries
  none; a call that ended without ever being answered carries neither a direction nor a length.
- **The row is written when the call ends, not when it rings.** A ring emits nothing, and the single row comes
  from the end of the call — `ended`, `missed`, or the settled `unknown`. This is the #532 review's blocker: the
  first version emitted at the ring *and* at the end, so every call reached the parent twice, and nothing
  downstream merges two rows (`POST /v1/devices/:id/activity` is a plain `createMany`, and the payload carries no
  key). The price is that a live call is not on the timeline until it ends — and that a call is lost if the
  service is destroyed mid-call, which is stated in the tracker's KDoc beside the 5 s hold.
- **The length is talk time, not ring time.** `ended` measures from the change that answered the call, so a call
  that rang 25 s and then talked 10 s reads `≈ 00:10`, not `≈ 00:35`; the row itself stays dated to the ring, so
  the timeline says when the phone rang. In Claude's capture that is 37 s rather than 39 s.
- **"Answered" is measured, not guessed.** A change on the same notification key with the importance falling
  (4 → 2 in the capture) **or** the channel moving from the `voip_notification` prefix to
  `silent_notifications` marks the call answered, and only an answered call gets a duration. The channel is
  matched on its **prefix**: the capture's suffixes (`_4`, `_3`, `_1`) are numeric and move between calls.
  `FLAG_FOREGROUND_SERVICE` is deliberately not a signal — the capture's outgoing call carried it from its first
  row.
- **An ignored call is one row.** Its removal is held for up to 5 s for the `missed_call` notice, which arrives
  on a **different** notification id (23 vs 4) about 1.2 s later, so the two are paired on package, Android user
  and timing, never on key. Without the hold, an ignored ring became a missed row plus a phantom "ended" row.
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
- **The caller's name travels in `payload.number`, and is a name from then on.** WhatsApp gives a display name
  and never a number; the parent app already labels rows by `payload.number`, so a separate `contact` field
  would have cost a second client change for nothing (ruled: Claude, #532). Because `"Mama 2"` normalises to
  `"2"`, nothing may normalise, dial or allowlist-match a call row whose `source` is `whatsapp` — recorded at
  `Entities.kt:33`, and `recordCall` never reaches `maybeAlertUnknownContact`.
- **The row is durable and typed.** `CommsEventEntity` gains `source` and `durationApprox`, and its `durationSec`
  becomes nullable (Room 3 → 4, a table rebuild around the same rows so a queued upload survives the upgrade).
  A null duration is **omitted** from the wire rather than sent as `0`; `CommsPayloadPolicy` is the pure mapper
  that does it, so `CommsLogger` is a one-line caller and the absence is a unit test.
- **Consent still gates everything:** the pause is checked before the notification is read and again before the
  row is written, and the listener keeps recording nothing while revoked (ADR-0008 §3).
- Rows: `WhatsAppCallTrackerTest` (10) — the capture's three calls replayed, each scenario summing **every** list
  the tracker returns and asserting one: answered (37 s, `≈`), missed (paired across ids), outgoing (one unknown
  row, no duration), user 95, plus prefix-only answering, a no-op re-post, the deadline, another package's
  notice, one identity, and (j) nothing emitted until the call ends. Plus 3 new rows in `WhatsAppCallPolicyTest`
  and 4 in `CommsCallPayloadTest`.
- **Not verified here, and named so a green suite is not read as more:** delivery to our own listener on real
  silicon (the capture ran with the agent uninstalled), a call to the user-95 clone, whether a *connected
  outgoing* call ever changes channel, and the **Room 3 → 4 migration**, which no JVM test exercises — its
  evidence is that the DDL matches the generated `FamilyShieldDatabase_Impl` column for column, and installing
  this build over a v3 build with a row still queued is what proves it. Those four are owed on the Flip4 before
  the row moves to ✅.
