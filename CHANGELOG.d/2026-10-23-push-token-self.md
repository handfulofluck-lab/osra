### API — the push-token route is device-only, and a device writes only the token it holds (#319)
- **`POST /v1/devices/:id/push-token` is the agent's own registration path again — and its only
  caller.** The path is unchanged, so the Android client needs no change; what changed is who may
  call it and what it takes. preHandlers: `requireFamily` (family scoping), a `device` role gate
  (`403 device_role_required` — the same refusal `GET /:id/commands` sends inline, lifted into
  `requireDeviceRole`), and `requireOwnDevice()` (a sibling device in the same family is `403
  forbidden`). The role gate is **not** redundant with `requireOwnDevice`: that helper lets every
  parent token through, because for a parent token the family scope is the whole rule.
- **The parent capability is removed on purpose** (architecture decision, Claude, 2026-10-23, issue
  #319). A parent writing a child's notification token had no legitimate caller. The old
  `requireParent` + `requirePermission("devices")` shape is gone, so audit finding 6 / #124's "a
  co-parent without `devices` may not repoint a child's notifications" becomes the stronger "no
  parent may, permission or not" — owner included. The route's comment says so, so a later reader
  does not "restore" it.
- **Body `{ token }`, 20–4096 characters** — the same field and bounds as `POST /v1/me/push-token`.
  The old `{ pushToken }` body is now a `400`, deliberately: a client that still sends it should
  find out rather than believe it registered.
- **One token, one device.** One transaction clears the token from every other device row
  (`updateMany({ where: { pushToken: token, id: { not: id } }, data: { pushToken: null } })`) and
  then sets it on this one. Push delivery addresses a registration token, not a row, so a phone that
  is unpaired and paired again — possibly into another family — would otherwise leave its old row
  waking a phone that now belongs to someone else.
- **Response `204`, no body.** No device object is returned, so nothing (`internalSecret`,
  `pushToken`) can leak through it and the `sanitizeDevice` allowlist the old parent route needed is
  no longer on this path.
- **No consent gate.** Stop-ring stays allowed after consent is withdrawn (an earlier decision), and
  a registration token is not the child's data.
- **The first shape was the development lead's default, and was overruled.** Because #319 was silent
  on the contract, this branch first carried an additive `POST /:id/push-token/self` next to the
  parent route, with the parent route untouched. Claude's decision against exactly that, quoted: *"It
  would keep a parent capability that has no legitimate caller, and it would leave the Android client
  pointing at the refused path."* `/self` is deleted; nothing in the API serves it.
- **The Android half is a separate PR.** Wake-up-only push (a data message that wakes the agent,
  with the 60 s poll as the fallback), the conditional gms plugin and re-publishing a token minted
  before pairing (`PushTokenUploadPolicy`) are not in this change. The API contract lands first so
  that PR has a route to call.
- **Evidence in this revision, and what is not evidence.** `pnpm --filter @familyshield/api test` →
  **39 files / 511 tests green**, `test/devices.test.ts` 29; `pnpm exec tsc --noEmit` clean. Mutants
  measured and reverted, one per assertion: removing `requireOwnDevice()` turns the sibling case into
  a `204`; dropping `requireDeviceRole` lets a parent write (`204`); dropping the `updateMany` leaves
  the first device holding the token; reverting `PushTokenSchema` to `{ pushToken }` fails three
  tests; answering `200 { ok: true }` instead of `204` and dropping the write each fail the success
  case. **Live gates, run by the lead on an isolated stack** (database `osra_319`, API on `:3010`,
  Redis db 1): `node scripts/qa-probe.mjs` → **166 passed · 0 failed · 2 targets · 0 notes**, with
  `P1` `204`/empty body, `P2` sibling `403 forbidden`, `P3` parent `403 device_role_required` and the
  strengthened `N6d` (co-parent *and* owner both refused) all green; `node scripts/e2e.mjs` →
  **71 passed · 0 failed**. Roadmap 1.5's acceptance — a `lock` landing in under 5 s with the app
  backgrounded — is unmeasured and remains Claude's hardware row; the Android half is a separate PR.
