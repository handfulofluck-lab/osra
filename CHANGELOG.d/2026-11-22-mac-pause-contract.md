### Mac pause: the accepted/applied split, as tested logic (#990, stacked on #988)
- `PauseState` / `PauseStateStore`: the parent's last request (`desired`) with a monotonic operation counter, persisted atomically at `0600` so a restart knows what was asked and a Standard user cannot fake it. A missing or corrupt file reads as unpaused, never as paused.
- `PauseSequencer`: three events and no others — **accept** (assign the next operation, report `pending`, never `applied`), **confirm** (only the current operation counts; an older confirmation is discarded as stale), and **restart** (`desired` wins, so a crash cannot leave a child offline).
- Eight contract tests, one per rule, including the late-pause-after-newer-resume case and the confirmation that names an operation the daemon never assigned.
- `pause_internet` stays `unavailable` in the capability report: a command ack is not a capability, and the signed activation row has not run.
- Not in this change: the `CommandDrainer` wiring and the filter's drop-all while paused. Both need the signed Mac to prove the agent's own traffic stays exempt, so they land with the row rather than ahead of it.
