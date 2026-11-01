### API — each device reports what it can enforce, and the parent sees it (ADR-0034 PR 1a)
- **One vocabulary, shared.** `DeviceCapabilitiesV1` in `packages/shared-types`: `client` (app, version, build,
  flavour), `grants` (the platform's real keys, including `usb_debugging` and iOS's three from A6), `features`
  (the ten), and the four states. The agent's Kotlin mirror comes with PR 2.
- **The server decides `not_supported`, from a table of build facts** (A1). Play cannot log calls or scan
  notifications; every iOS flavour cannot lock, pause, uninstall-guard or read calls. A device that claims
  `not_supported` **outside** its own row is stored, shown as `unavailable`, and counted as a fault — otherwise a
  modified agent could turn a fault into a quiet grey row.
- **The report is strict and small** (A2): enum keys, enum values, nothing else, 4 KB. A bad one answers **400 for
  the `capabilities` field** while the rest of the same telemetry upload is stored; `pair/claim` accepts the same
  object and refuses a bad one before reserving a claim.
- **The server's receipt time is the only clock** (A4): `capabilitiesReportedAt` is set when the upload arrives, and
  a timestamp inside the report is refused by `.strict()` rather than ignored.
- **"Phone setup" on both device reads** (decision 3): `reportedAt`, `stale` past 20 minutes, `features` with
  `not_supported` recomputed from the table, and `missing` — the grants the device says it lacks. A device that has
  never reported shows "not reported yet", never "all missing".
- **A command the phone cannot run is failed, not queued** (decision 3, replacing `locateNowRefusal` for one
  command with the general rule): refused at once from the table whatever the report's age (A1/claim 13), refused
  with the feature's own reason on a fresh `unavailable`, and **queued** for `degraded`, for a stale report and for
  a device that never reported. `degraded` is never a refusal: the agent applies it, so failing the command would
  be the server contradicting the phone.
- **Rows:** `capability-table.test.ts` (5), `capabilities.test.ts` (14) and `capabilities-routes.test.ts` (8) —
  claims 8, 9, 11 and 13 at both the library and the route, plus "a lock with a fresh `unavailable` is refused",
  "the same lock at 21 minutes is queued", "a `degraded` report queues", and "an upload without the field keeps the
  stored one".
- **Not in this PR:** the `X-OSRA-Client` header, `X-OSRA-Update` and the 426 gate — that is PR 1b. `locationGrant`
  is untouched, as the ADR requires for two releases.
