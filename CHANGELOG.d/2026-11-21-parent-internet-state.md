### Parent app — the internet chip's four states, read from the acknowledgement aggregate (#969)
- The dashboard chip read only `paused` from `GET /v1/controls/children/:id/status`, which reports whether the command
  was **sent**. It could sit red over a phone that was still online. That is Codex's #969 report.
- Codex's aggregate (`services/api/src/lib/childInternet.ts`, merged as #981) now returns
  `internetRequest.devices[]` — one entry per device **of this request**, with the status of its own command id.
  The server does the part a client cannot: a device that never received the request is `unknown`, and a command whose
  window closed is `expired` or `unconfirmed` instead of silently pending.
- `internetStateFor` maps those statuses to **inactive / waiting / confirmed / partial**. Only `acked` counts as
  confirmed; `delivered` does not; `failed`, `expired` and `unconfirmed` all keep the state out of `confirmed`, and a
  mixed result stays `partial` rather than being rounded to one side.
- **No user-visible text in this change.** The three wordings are with the Bureaus (#650 `7051817882`, #604); the chip
  is wired when they land. This is the state derivation and eleven fixture rows.
