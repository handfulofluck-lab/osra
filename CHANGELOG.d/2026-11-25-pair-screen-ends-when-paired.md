### Parent app — the Pair a device screen ends when the phone is paired (#1134)
- After the parent approved the phone and it took its token, the standalone **Pair a device** screen stayed on the
  scan instructions, so the only way out was the system Back button. It now ends on the paired state — the same
  «{device} is paired.» line the wizard already shows — with a **Close** button back to the child card, which lists
  the new device.
- The pairing wizard is unchanged: it still advances through its own Continue step.
