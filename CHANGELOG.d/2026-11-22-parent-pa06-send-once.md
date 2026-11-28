### Parent app — one tap is one command (#738, child-escape catalogue row PA06)

A parent who tapped Ring twice, or tapped Ring on the map and then on child detail, queued the command
twice and left two rows in the device history. Both senders (`child_detail_screen.dart`,
`family_map_screen.dart`) now share one in-flight guard, keyed by **device and command**: the same command
while its POST is outstanding is dropped, a different command in the same instant still goes (a quick lock
then unlock is two intents), and a failed POST releases its claim so the control is retryable.

- `lib/core/command_in_flight.dart` holds the guard; both senders call it in `_sendCommand` and release in
  `finally`.
- `test/escape_pa06_send_once_test.dart` — four rows: double tap on child detail, lock-then-unlock in the
  same instant, retry after a `503`, double tap on the map sheet. Mutants run and recorded in the file:
  dropping the early return reds the double-tap rows, keying by device alone reds the lock/unlock row, and
  dropping the release reds the retry row (and the map row, because the leaked claim is shared).

No copy, Arabic or otherwise, changes here. The server-side half of the row ("last intent wins on the
child", "history shows each command once" under retry) is a `qa-probe`/API row and is not covered by this PR.
