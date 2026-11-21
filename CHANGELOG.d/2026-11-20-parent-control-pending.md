### Parent app — a queued Pause or Resume says it is still waiting on the phone (#969)
- The device card's Pause and Resume buttons looked idle the moment the request was accepted, because the POST
  answers `{status: "pending"}` before the handset has seen it. A parent who tapped Resume and saw nothing had no way
  to tell "asked, not done yet" from "nothing happened".
- While the newest command of that type is `pending` or `delivered`, the control is **disabled at the button itself** —
  `onPressed: null`, so touch, TalkBack, VoiceOver, Switch Access and the keyboard's Enter/Space all honour it —
  with the catalogue's existing "Pending — waiting for the device" line as its tooltip. `acked`, `failed` or
  `expired` restores it.
- Only the newest command of that type decides, so an old row that never settled cannot keep the button blocked
  after a newer one was acknowledged.
- No new copy and no renamed label: this adds a state to the row, and the wording change for the two controls'
  scope is waiting on the UI/UX and Arabic Bureaus (#650 `7048925646`, #604 `7048930748`).
- Five widget rows: a queued pause is marked and a different command is not; a `delivered` command is still pending;
  an `acked` one leaves the control usable; a stale pending row does not outvote a newer acknowledged one; and the
  pending button's own `onPressed` is null, so it is disabled for assistive tech and the keyboard too.
