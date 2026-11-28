### Parent app — a spent pairing code cannot come back on screen (#1149)
- The pairing screen asks the server every two seconds whether the phone has claimed its code. A slow answer could
  arrive after a newer one: an earlier "approved" then overwrote a confirmed "paired", restarted the poll and put the
  spent QR back in front of the parent.
- Two guards now hold: an answer from an older read is dropped, and a claim that is already paired is never
  overwritten by an earlier state. Regression test drives the responses out of order on purpose.
