### API — device-reported data and location pings are device-only; editing a child needs `rules` (plan 2.7)
These are the fixes for findings F2–F4 and one consistency fix from the plan 2.7 authorization review. Claude
decided them on #329 (2026-10-23).
- **Device data (F2).** `POST /v1/devices/:id/telemetry`, `/:id/activity` and `/:id/apps` now refuse every parent
  token with `403 device_role_required`. That covers owner, co-parent and guardian, with any permission.
  Before, any adult in the family could forge the app inventory that feeds app blocking, the calls and texts
  in the activity log, and the usage minutes, because `requireOwnDevice` lets parent tokens through.
  - The gate is `requireDeviceRole`, already used by `/:id/push-token`.
  - The unit tests that pinned a parent's `202` now assert the `403` and name the decision.
  - e2e posts telemetry with the agent's token, and adds a parent-refused check.
- **Child edits (F3).** `PATCH /v1/family/children/:id` needs the `rules` permission. The owner always passes.
  `birthYear` sets the age risk scoring uses, so a guardian with no permissions could change how strictly a
  child's messages and searches are judged.
- **Location pings (F4).** `POST /v1/location/ping` accepts a device JWT or an HMAC signature only. A parent JWT
  is `403 device_role_required` before the body is read, so nothing is stored and no geofence or routine is
  evaluated.
  - Before, a parent ping could move a child into a geofence whose routine applies rules, getting around the
    `rules` permission, and could falsify the location history. No client sent one.
  - The parent-only `device_mismatch` branch is gone. The device-token `device_mismatch` check stays.
  - Probe G15 and G16 are superseded in `scripts/probe-gate-acks.json`. G17 now names its error.
- **`ws-ticket` and purpose tokens (Q4).** `POST /v1/ws-ticket` answers a purpose-scoped token (password reset,
  MFA recovery or reset) with `401 unauthorized`, like every other route, instead of
  `403 parent_role_required`. This is consistency, not exposure: the token was refused before too.
- **Measured on a local stack:**
  - API unit suite 523/523.
  - Probe 169 passed / 0 failed.
  - e2e 72 passed / 0 failed.
  - The 7 new or changed unit tests fail against `origin/main`'s routes and pass with the fix.
  - Restoring the old parent pass-through in `pingAuth` makes probe G15 and G17 fail.
