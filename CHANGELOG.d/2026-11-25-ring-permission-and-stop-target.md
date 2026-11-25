### OSRA Kids iPhone — the ring permission is main-actor isolated, and Stop targets the ring that is ringing (#1124)
- `@MainActor` on the ring permission was glued to the end of a doc sentence, so it was part of the comment and the
  class was never isolated; the published status could be written from the authorizer's async completion off the main
  actor. It now sits on its own line.
- Parent **Stop ring** now names the newest ring the device may still be ringing. A child acknowledges a ring when
  it *starts* sounding, not when it ends, so the parent client previously aimed Stop at an older ring while a newer
  one rang — and a later version of the same rule could pick a superseded row the child refuses, leaving the phone
  ringing. It now takes the newest ring that is queued, delivered or acknowledged; failed and expired rows never rang
  and are skipped.
