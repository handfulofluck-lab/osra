### API — a device command now wakes the phone over FCM instead of waiting for the poll (#319, roadmap 1.5)
- `enqueueDeviceCommand` — the single funnel every command producer goes through (controls, rules,
  auth, devices) — fires one detached wake to that device's `Device.pushToken` after the row is
  committed and the Redis publish is attempted. Before this, a backgrounded phone learned about a
  command only on its next 15-minute WorkManager tick, which is why 1.5's acceptance ("a lock lands in
  under 5 s with the app backgrounded") could not be met however fast the encryption was.
- **The push carries no command.** Payload is `{ type: "wake" }`, a fixed literal, and the message is
  data-only: no `notification` block, `android.priority: "HIGH"`, `collapse_key: "wake"`. Google never
  sees command content — `show_reset_code` carries a parent's reset code and `locate_now` carries the
  timing of a family's day — and on a stale or misdirected token the message gives nothing away.
  Ten commands in a second cost one wake, because the agent drains the whole queue on the first.
- **One code path.** The agent answers a wake by draining `GET /v1/devices/:id/commands` on its own
  authenticated channel (client half: the Android PR), so poll and push share the same idempotent acks.
- **A wake never fails a command.** The promise is detached and its rejection swallowed: the row is
  already durable, and a slow Google round trip must not delay the parent's POST.
- **A dead token is cleared.** `UNREGISTERED` / 404 / `INVALID_ARGUMENT` sets `Device.pushToken` to
  null — the only place a device token is ever removed; the agent re-registers on its next
  `onNewToken` or poll tick and `PushTokenUploadPolicy` republishes it.
- **Nothing is sent when push is disabled.** With no provider configured (no
  `FCM_SERVICE_ACCOUNT_JSON` / `APNS_*`, which is what `push_enabled=false` produces) the wake is
  skipped with one warn per process, exactly like the parent alert path.
- `PushMessage` gained `dataOnly?: boolean` and lost its required `title`/`body`; both providers build
  a data-only payload without an alert. An ordinary alert payload is unchanged, and a test pins that
  the data-only branch does not leak into it.
- **Evidence.** `pnpm --filter @familyshield/api test` → **39 files / 518 tests passed** (8 new in
  `test/push.test.ts`); `pnpm exec tsc --noEmit` clean; live gate on an isolated stack (database
  `osra_wake`, API `:3011`, Redis db 2): `node scripts/qa-probe.mjs` → **164 passed · 0 failed**, and
  `node scripts/e2e.mjs` → **71 passed · 0 failed**, with the wake firing on every command they send.
  Mutants measured, then reverted: `dataOnly: false` fails three tests (the FCM body gains a
  `notification`, the APNs `aps` gains an alert); commenting out the wake call in
  `enqueueDeviceCommand` fails the once-per-command test (`1 failed | 18 passed`).
- **Not verified here:** no live FCM project was contacted, so the Google round trip, the
  `UNREGISTERED` clearing path against the real service, and the end-to-end 5-second measurement are
  unobserved. The hardware row is Claude's and needs a push-enabled staging session.
