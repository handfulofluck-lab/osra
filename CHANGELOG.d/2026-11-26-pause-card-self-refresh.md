### Parent app — the device card settles Pause and Resume without a pull-to-refresh (#1167)
- A pause or resume the child's phone had already applied could leave the card on "Pausing…" or
  "Resuming…" until the parent pulled to refresh, because the card learned the outcome from one
  realtime frame and nothing replaced a frame that did not arrive.
- While the card is waiting on the handset it now re-reads that one device's command history on a
  bounded backoff — six reads over about three minutes — and stops. Push still settles the card first
  when the frame arrives; the control still stays unusable until the server confirms the handset acted.
