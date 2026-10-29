### Pairing — two follow-ups to the parent's approval (plan 2.7, #433 review)
- Parent app: after **Deny**, the pairing screen shows only the Declined card and its new-code button. The
  burned code's QR, digits, countdown and copy action are no longer drawn under it.
- Android: what was typed into the pairing form — server, code and **device name** — survives a fold or a
  rotation. The fields are built in code and kept no state, so on a Flip4 a fold brought the QR review back
  with an empty name and the phone registered under its model name. Not yet confirmed on the phone; the fix is
  for Claude's next Flip4 run.
