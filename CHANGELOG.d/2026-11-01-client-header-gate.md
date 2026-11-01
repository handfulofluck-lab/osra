### API — every client names its build, and the server can answer "update" (ADR-0034 PR 1b)
- **`X-OSRA-Client` is parsed, not trusted** (A3): a 64-character cap before any parsing, then the pattern
  `<app>/<version>+<build> (<flavour>)`. Anything else is **legacy** — absent, malformed, a repeated header, or an
  app the server does not know — and legacy is served exactly as today, which is what keeps every already-released
  client working. Only the parsed fields are ever logged; the raw header is client-controlled text.
- **Every response carries `X-OSRA-Update`** — `none`, `recommended` or `required` — computed from that request's
  own header. An app that reads it can prompt; one that does not loses nothing.
- **The 426 gate is off as this ships.** `CLIENT_POLICY` is read from env and ships empty; an unreadable value
  means "no policy", because a broken environment variable must never lock a parent out. When it is set, only the
  **parent app** below `min` is refused (`426 update_required`), and **the child agent never is** — a refused agent
  is an unmonitored phone, so the pressure goes to the parent instead (decision 5).
- **A5: the gate never blocks a data right.** `/health`, logout, logout-all, consent revocation and child deletion
  stay open, so a parent on an old app can always withdraw consent and delete a child's data.
- **The build is stored with the client it belongs to** (A3): a device's own request writes its build to its own
  `Device` row, and a parent's request writes to that parent's push-token rows. A parent opening the device screen
  passes the same family check, so without that split the dashboard would overwrite the phone's build.
- Migration `0032_client_build` adds the four columns on `Device` and three on `ParentPushToken`, all nullable: a
  client that sends no header reports nothing, and null must read as "not reported", never as "oldest".
- Rows: `client-header.test.ts` (11) and `client-header-hooks.test.ts` (8). Faults measured: the same-device rule
  removed (claim 10), one A5 exemption dropped (claim 12), a malformed header answered with 400, and the gate
  applied to the child agent (claim 6) — each reddens its own row. The malformed-header fault **survived the first
  version**, because the library row proved the parser returns null and nothing proved the hook does not refuse on
  the way in.
