### API — three revocation checks that duplicated the global gate are gone (#387, #351)
- `location.ts`, `realtime/gateway.ts` and a router-scoped hook on `deviceRoutes` each did
  `GET revoked:device:<id>` and answered `401 device_revoked`. The global `sessionGuard` hook
  (`server.ts:78`, from #349) already answers that **before** any route, using `deviceVerdict` —
  tombstone, then a five-minute positive cache, then the row. So the three were unreachable for a revoked
  device and cost a Redis GET per ingest, per poll and per socket ticket.
- **What this PR had to do besides delete them.** The test harness mounts the gate only when asked
  (`buildApp(..., { sessionGuard: true })`), and `token-hygiene.test.ts` was asserting the 401 that the
  router hook produced. Deleting the hook alone would have left that test green while testing nothing. It
  now mounts the production gate, and removing `{ sessionGuard: true }` turns it red — the pair is the
  proof, not the deletion.
- Verified: API **603 passed (46 files)**; `tsc --noEmit` clean; the `token-hygiene` case is red with the
  gate unmounted and green with it mounted.
- The fourth mechanism stays: `location.ts`'s FK-violation mapper (`:291`) answers the same error for a
  missing row, and `geofence.test.ts:896` pins it. It is an error mapper, not a revocation check.
