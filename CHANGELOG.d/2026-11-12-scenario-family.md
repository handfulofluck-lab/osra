### Scenario suite — a throwaway family in one call, erased and proved (`scenario-family.mjs`, #668)
- `scripts/hardware/scenario-family.mjs create` signs a parent up, adds a child with inline consent,
  neutralises the child's screen-time windows through `PATCH /v1/rules/:childId` (no daily limit, no
  bedtime window, no school days), mints a pairing code and prints **one JSON object**:
  `{ familyId, childId, pairingCode, parentTokenFile }`. The access token and the password `delete` needs
  go to that file at mode 0600 — never to stdout, never to a log line.
- `create` reads the ruleset back and refuses to mint a code for a family whose defaults survived; a create
  that fails after the sign-up erases the partial family instead of leaving an account behind.
- `delete` re-authenticates with the password the file holds, erases the family with `DELETE /v1/family`
  (the ADR-0013 cascade), then proves it: each child-scoped table TR-06 counted is read through its own
  parent route afterwards and must refuse. Non-zero counts exit 1.
- Both subcommands refuse a base URL that is not `localhost`, `127.0.0.1` or `*.staging.osratech.com`,
  as a named `BaseUrlRefused` with exit 2 **before the first network call** — the script creates and erases
  accounts, so a typo that points it at a real stack is not a mistake worth surviving.
- `scripts/hardware/scenario-family.test.mjs` (`node --test`, no dependencies): the four refused URL
  shapes and three accepted ones, the 0600 token file and its absence from stdout, usage exit 2 on an
  unknown argument, and "delete after create leaves nothing" — skipped with a reason unless
  `SCENARIO_API_BASE` is set, and a **failure** on non-zero counts when it is.
- Not verified in this change: the live case has not been run against a stack (no staging window, no local
  API from the authoring session), and the row-level Postgres count stays `e2e.mjs`'s with `DATABASE_URL` —
  no public route counts rows. On Windows the 0600 mode is advisory (NTFS keeps 0o666) and the script warns
  instead of pretending.
