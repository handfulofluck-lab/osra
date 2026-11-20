### Parent app — a queued Pause or Resume says it is still waiting on the phone (#969)
- The device card's Pause and Resume buttons looked idle the moment the request was accepted, because the POST
  answers `{status: "pending"}` before the handset has seen it. A parent who tapped Resume and saw nothing had no way
  to tell "asked, not done yet" from "nothing happened".
- While the newest command of that type is `pending` or `delivered`, the control is now shown dimmed, non-tappable and
  with the catalogue's existing "Pending — waiting for the device" line as its tooltip. `acked`, `failed` or
  `expired` restores it.
- No new copy and no renamed label: this adds a state to the row, and the wording change for the two controls'
  scope is waiting on the UI/UX and Arabic Bureaus (#650 `7048925646`, #604 `7048930748`).
- Three widget rows: a queued pause is marked and a different command is not; a `delivered` command is still pending;
  an `acked` one leaves the control usable.
