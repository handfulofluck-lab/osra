### Child Android — a ring keeps its floor while it is active (osra-security#42)
- Karim's Flip4 report: the alarm became quieter while the ring stayed active. `Ringer` set the alarm stream to
  its maximum and played on `USAGE_ALARM`, but nothing defended that level afterwards.
- Two gaps closed: the ring now holds **`AUDIOFOCUS_GAIN`** (so another app cannot duck the alarm) and watches
  `VOLUME_CHANGED_ACTION` on `STREAM_ALARM` — the hardware keys still work from the lock screen, the shade or
  another app, where `RingActivity`'s key-swallowing cannot reach. A drop below the floor is raised back and
  counted in `Ringer.volumeRestorations`.
- The decision is pure: `RingPolicy.volumeVerdict(current, floor)` returns `RESTORE` only for a downward change
  with a floor to defend, `IGNORE` otherwise.
- Focus is abandoned and the receiver unregistered on every stop path; the original stream volume is restored
  exactly as before.
- Rows: `a volume drop below the floor is put back, anything else is left alone` (three cases) and a wiring row
  that fails if any of the focus hold, the watch, the verdict call or the cleanup is dropped.
- **Not in this PR, and stated as such:** the parent-visible sentence for "the child tried to silence the ring".
  The count is now available; the wording needs one Bureau string in both languages, and the parent app needs a
  row for it. Ahmed's report asks for the report *and* the fix — this is the fix half, deliberately.
