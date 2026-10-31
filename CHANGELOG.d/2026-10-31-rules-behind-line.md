### Parent app — "The phone hasn't picked this change up yet" (#475, app half)
- **Where it shows:** a banner at the top of the rule editor, the screen where a parent changes the rules — so
  the sentence appears where the change was made, not in a diagnostics page. One line, no dismiss button:
  it is not an announcement, it is a state.
- **The comparison is one pure function**, `rulesAreBehind(child)`, with three states and **one** that warns:
  `applied < rules` warns; `applied == rules` does not; **`applied == null` does not**, because a phone that
  has never reported is not a phone that is behind, and a warning there would fire on every fresh install
  and teach the parent to ignore the one that matters. A version *above* what the server issued cannot come
  through it (the server only stores versions it issued) and is treated as not-behind: a warning built on a
  number we did not issue would be a second bug.
- **The two numbers ride `GET /v1/family/me`**, the request the rule screens already make, so the app does
  not pay a second round trip that a screen could forget. `GET /v1/family/children/:id` answers the same
  pair from the same rule, and **one row pins them against each other** rather than each on its own.
- `Child` gains `rulesVersion` / `appliedRulesVersion`, both nullable: absent from an older server reads as
  "nothing to say", not as "behind".
- Rows: `rules_freshness_test.dart` — five pure rows (behind, equal, never reported, no server version, a
  version above) and three widget rows (the banner appears; a current phone and a never-reporting phone show
  nothing; the Arabic line under `ar`/RTL). Mutants run: `applied != rules` reddens the never-reported row;
  hiding the banner reddens the widget row; `max` instead of `min` on `/me` reddens the parity row.
- **The Arabic is still a draft** («لم يلتقط الهاتف هذا التغيير بعد.») and goes to Karim with Q10's line; it
  is in `app_ar.arb` so parity holds, and a rewording is a strings-only change. It is **pinned as a literal**
  in the RTL row the way #486 and #491 pin theirs, so a rewording has to move the row too rather than arrive
  silently — which is the point of pinning draft wording, not a claim that it is final.
