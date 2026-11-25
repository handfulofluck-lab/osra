### OSRA Kids iPhone — the ring permission is main-actor isolated, and Stop targets the ring that is ringing (#1124)
- `@MainActor` on the ring permission was glued to the end of a doc sentence, so it was part of the comment and the
  class was never isolated; the published status could be written from the authorizer's async completion off the main
  actor. It now sits on its own line.
- Parent **Stop ring** picked the newest *acknowledged* ring command, and an acknowledgement is the device saying the
  ring already ended. With a newer ring starting and its acknowledgement late, Stop was aimed at the old ring and the
  phone kept ringing. It now targets the newest ring the device may still be ringing — sent or delivered — which is
  the same rule the server applies to its own ring rows.
