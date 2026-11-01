### Parent app — a call row says only what the phone measured (#4.5, parent-app half)
- **Direction is shown only when it was measured.** `outgoing` → `call_made`, `incoming` → `call_received`,
  `missed` → `call_missed`, and **anything else → the neutral `Icons.call`**. The phone-side parser sends
  `unknown` for a WhatsApp call, because WhatsApp keeps the ongoing-call notification for outgoing calls too
  (#523); an arrow there would state a direction nobody measured.
- **A duration is shown only when one exists.** Nothing for a missed call or when the agent sent none — reading
  an absent value as `0` rendered "0:00", which says the call connected and ended instantly. `durationSec` is
  now nullable on `ActivityEvent`, so absent stays absent.
- **`≈` when it is approximate.** `durationApprox` marks a call whose length was measured from notifications
  rather than timed, and the row reads `≈ 0:31`.
- **A WhatsApp subtitle.** `source == 'whatsapp'` adds "WhatsApp" under the number. It is a brand name, so the
  same text in both languages and no new Arabic to approve.
- Rows: `call_rows_45_test.dart` (5) — a carrier incoming call reads exactly as before; a WhatsApp call with an
  unknown direction shows the neutral icon, `≈ 00:31` and the subtitle, with no `call_received`; a WhatsApp
  missed call shows `call_missed` and no duration; an absent duration shows nothing rather than `0:00`; and **a
  carrier missed call with `durationSec: 0`** shows no `00:00` — the case the guard exists for, since Android's
  call log stores 0 for a missed call and the agent uploads it as 0.
- Mutants, measured: `unknown` mapped back to `call_received` reddens (b) alone; the `≈` dropped reddens (b)
  alone; `durationSec` read as `?? 0` reddens (d) alone; **removing only the `missed` half of the guard reddens
  (e) alone** — the earlier version of this file left that fault green, which is why (e) exists.
- **The duplicate row I flagged was my fixture, not the screen** (#526 review): `activityProvider` asks
  `/v1/reports/activity` twice, once per type, and my fake ignored `type` and answered the call twice. The route
  now filters like the server, the rows assert `findsOneWidget`, and the WhatsApp assertions are scoped to
  `CallsSmsSection` because the monitoring toggles above carry the same app names.
