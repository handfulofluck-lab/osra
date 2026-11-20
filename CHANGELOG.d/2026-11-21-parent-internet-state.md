### Parent app — the internet chip's four states, derived from what the phone confirmed (#969)
- The dashboard chip reads `GET /v1/controls/children/:id/status`, which reports whether a `pause_internet` command
  was **sent**. It has never reported whether a handset applied it, so a red "internet paused" could sit over a phone
  that was still online. That is Codex's #969 report.
- The confirmation is already on the wire: `pause_internet`/`resume_internet` fan out as one `DeviceCommand` per
  device (`pending → delivered → acked|failed|expired`). `internetStateFor` maps the newest row per device plus the
  requested flag into **inactive / waiting / confirmed / partial**: only `acked` counts as confirmed, `delivered` does
  not, and a mixed or refused result stays `partial` instead of being rounded to one side.
- `newestInternetCommand` returns null when a device has no internet row at all, so "unknown" is never read as
  "waiting" by mistake.
- Only a row for the **requested action** counts: an acknowledged `resume_internet` can never confirm a pause, and a
  device that has no row for the request keeps the child's state at `partial` rather than letting the others round it
  up to success.
- **No user-visible text in this change.** The three new wordings are with the Bureaus (#650 `7051817882`, #604), and
  the chip is wired to them when those land. This is the state machine and its fixture rows, as Codex asked.
