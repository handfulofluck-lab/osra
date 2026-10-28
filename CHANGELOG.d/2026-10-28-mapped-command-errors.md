### Parent app — a command refused by an error now says why (#434)
- A refusal can arrive two ways: a `200` with `{status:"failed", reason}` (mapped since #221) or an HTTP error whose
  body carries `error`. The second one was shown to the parent as the wire code inside `Command failed: {error}`.
- `commandErrorText` orders the mapping the way a parent needs it: a **reason** the agent would have used goes through
  `commandRefusalText` (one cause, one sentence, whichever path refused); `forbidden` / `not_owner` become "you do not
  have permission … ask the family owner"; `rate_limited` / `too_many_requests` say to try again shortly. **Anything
  else stays verbatim** — hiding an unknown code behind a generic "failed" is the same mistake as reporting a refused
  command as queued, because it removes the one clue the parent or we have.
- Wired on both command paths: the family map's Ring/Lock and child detail's command row.
- Rows pin Arabic literals (#429). Mutants: removing the permission mapping reddens both rows; putting the raw code back
  in the map reddens only the map row.
