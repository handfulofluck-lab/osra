### Child agent (Full) — a WhatsApp call becomes a call row: who, when, roughly how long (#4.5, parser first)
- **What a parent will see, once the wiring lands:** a call in the timeline for a WhatsApp/VoIP call, marked as
  such, with the caller's name, the time and "about N min". Never content: WhatsApp gives us a title and a
  notification, nothing else.
- **This PR is the parser only** — `WhatsAppCallPolicy`, pure and Android-free, so the decisions are a JVM test
  before any service touches a `StatusBarNotification`. Claude asked to review the parser before the wiring.
- **The decisions, each stated rather than implied:**
  - a heads-up is `incoming`, because a call the child *placed* produces no heads-up — the one inference here;
  - a duration is removal minus heads-up, so it is always `durationApprox` and the parent app can render
    "about N min" rather than a measurement;
  - a **missed** call has no duration at all — null, not 0, because "0 s" reads as a call that connected;
  - a re-posted heads-up (ring → in progress → removed) is **one** row, keyed by notification key plus start,
    while two calls from the same person in the same second stay two;
  - a clock that went backwards cannot produce a negative duration, and anything past 24 h is bounded;
  - `com.whatsapp.w4b` is the same app key, so a business profile is still the child's call.
- **Fault 4 is structural, not tested-for:** `Call` has no field a notification body could be copied into, and
  the row asserts the body's words survive in no field either.
- Rows: `WhatsAppCallPolicyTest` (7).
- **Not in this PR, and named in the test file so a green run is not read as more than it is:** the pause gate
  (fault 1), the Play-flavour exclusion (fault 6), and the server payload plus the parent app's `source`
  rendering (fault 7).
