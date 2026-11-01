### Child agent (Full) — a WhatsApp call becomes a call row: who, when, roughly how long (#4.5, parser first)
- **What a parent will see, once the wiring lands:** a call in the timeline for a WhatsApp/VoIP call, marked as
  such, with the caller's name, the time and "about N min". Never content: WhatsApp gives us a title and a
  notification, nothing else.
- **This PR is the parser only** — `WhatsAppCallPolicy`, pure and Android-free, so the decisions are a JVM test
  before any service touches a `StatusBarNotification`. Claude reviewed it before the wiring, and the four
  corrections from that review are in this revision.
- **A call is told from a message by `Notification.category`**, not by having a title: every WhatsApp chat
  message also carries the sender's name. `started`/`ended` require `CATEGORY_CALL`, `missed` requires
  `CATEGORY_MISSED_CALL` (API 30 — below it there is no missed row rather than a guessed one).
- **The direction of a live call is `unknown`, never `incoming`.** WhatsApp keeps an ongoing-call notification
  for *any* call, outgoing included, so a call the child placed looks exactly like one they received. Losing
  the arrow costs a detail; inventing it states something false about the child.
- **An unanswered call produces no `ended` row** — the `missed_call` notice owns that row. Without this, a ring
  that was ignored became two rows, one of them claiming 25 seconds of call.
- Other decisions, each in the KDoc: a duration is removal minus heads-up and always `durationApprox`; a missed
  call has **no** duration (null, not 0, which reads as a call that connected); a clock that went backwards
  clamps to 0 and anything past 24 h is bounded; `com.whatsapp.w4b` is the same app key; an unnamed call
  produces no row.
- **The body cannot reach the row from either side:** `Snapshot` has no `text` field and `Call` has no field
  that could hold one, so the adapter cannot pass it and the parser cannot copy it.
- Rows: `WhatsAppCallPolicyTest` (9), including the main one — a `msg`-category notification gives null from all
  three functions.
- **Not in this PR, and named in the test file:** the pause gate (fault 1), the Play-flavour exclusion (fault
  6), the server payload plus the parent app's `source` rendering (fault 7), and the real notification sequence
  (ring, answer, end, missed, outgoing) which is captured on the Flip4 before the wiring PR.
