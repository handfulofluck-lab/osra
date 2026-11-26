### API — a computer is pending, not "online", until its pairing proof is accepted (#790)
- **The bug:** `POST /v1/devices/pair/claims/:claimId/poll` created the Device row with
  `status: "online"` the moment the parent's Allow was taken. The phone then proves itself with the
  per-device HMAC secret the poll minted; a proof that is refused (a wrong key, a planted fault, a bug
  in a new agent) left a row the client cannot ask the server to remove, and the parent app showed the
  computer as a working phone for the 30 minutes until the silence job flipped it. Found by the Mac
  agent seat on #779.
- **What changed:** the poll now writes `status: "offline"` and leaves the new `Device.pairedAt` null.
  That is "pending": a row that exists so the approved claim has somewhere to put its secret, and that
  no parent surface shows. `Device.pairedAt` is set to the request time by the first request from that
  device the API *accepted* — one global `onResponse` hook (`middleware/pairedAt.ts`), not a call per
  route — and never rewritten. A refused request (401 `device_revoked`, a 403 for another device's id,
  a 400 body, a 428 consent stop) leaves it pending, because the hook reads the status the client
  actually received and every refusal is 4xx/5xx.
- **Invisible to parents, out of the count:** `GET /v1/devices`, `GET /v1/family/me` (its children's
  devices and its flat list), the GDPR export, the parent's device detail/apps/command/history/request
  reads (404, as if the row did not exist) and the MFA-reset witness count and reset-code fan-out all
  exclude a pending row. No parent-app change: the list simply does not contain it.
- **Expiry:** `jobs/pendingDevices.ts` (5-minute tick, Redis `SET NX` claim per device, `JOBS_ENABLED=0`
  respected) deletes a pending device whose `lastSeen` is older than 30 minutes, re-checking
  `pairedAt IS NULL` in the DELETE so a phone that answers in the window is never removed. Nothing is
  pushed or mailed to the parent — an alert about a phone they never saw would be worse than silence.
- **Migration `0038_device_paired_at`** adds the nullable column and backfills every existing row with
  `pairedAt = lastSeen`, so no device that works today disappears from a parent's list. The folder is
  0038: `0036_parent_consent_events` (#878) and `0037_device_last_boot_at` (#884) are on `main` already.
- `POST /v1/devices/register` (a parent's own enrollment, and what `e2e.mjs`/`qa-probe.mjs` use) sets
  `pairedAt` at creation: nothing claimed it, and a pending row would be hidden from the parent that
  created it. The demo seed does the same.
- No signed no-op route was added: the mechanism above clears pending on the agent's first accepted
  request, and every agent's next call after pairing is its command poll (its heartbeat, ≤ 600 s). A
  second route would be a new device surface for the same result. An HMAC-signed `/internal` write does
  not clear pending by itself (the route can still refuse the body), so a HMAC-only agent clears on its
  next device-JWT request.
- Verification, on the authoring host (memory-starved by the other agents' sessions throughout: 0.9–1.9
  GB free of 15.8 GB). Green: `npx vitest run test/pending-devices.test.ts test/pairing.test.ts
  test/devices.test.ts` — 3 files, 91 tests, all passed; and `test/mfa-reset.test.ts` alone — 41 tests,
  all passed. Not green as one command: the standard `pnpm --filter @familyshield/api test` reached 1152
  of 1159 tests, and every failure was "Test timed out in 20000ms" in argon2-heavy auth/MFA rows this
  change does not touch (a different set of rows each attempt), on a host where the same
  `mfa-reset.test.ts` takes 26 s, 184 s on a pristine `origin/main` checkout, and 422 s under load; one
  worker also died with `0xC0000409` (memory exhaustion). `npx tsc --noEmit` in `services/api` is clean.
  **Not run:** the live `qa-probe.mjs` and `e2e.mjs` — no live stack on this host — so the probe's own
  pairing rows have not been exercised against this change.
