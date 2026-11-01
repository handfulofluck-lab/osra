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
- Rows: `call_rows_45_test.dart` (4) — a carrier incoming call reads exactly as before; a WhatsApp call with an
  unknown direction shows the neutral icon, `≈ 00:31` and the subtitle, with no `call_received`; a WhatsApp
  missed call shows `call_missed` and no duration; an absent duration shows nothing rather than `0:00`.
- Mutants, measured: `unknown` mapped back to `call_received` reddens (b) alone; the `≈` dropped reddens (b)
  alone; a missed call rendered with `formatDurationMmSs(0)` reddens **(c) and (d)**, because both go through
  the same null guard — stated here rather than discovered later; `durationSec` read as `?? 0` reddens (d) alone.
- **Harness note:** under this fixture the calls section renders one event twice (a probe counted two number
  texts and two icons for a single call), so the rows assert `findsWidgets` rather than `findsOneWidget`. The
  rows still fail on a wrong icon or a wrong duration; whether the double render is real is flagged in the PR.
