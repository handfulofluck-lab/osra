### Security — a guardian reads alerts, places and activity only with the permission (ADR-0014 amendment, 2.7)
- `requireGuardianRead(permission)` in `middleware/requireFamily.ts` gates **reads** for the `guardian` role:
  owners and co-parents pass unchanged, a guardian needs the matching invite permission, and a device token is
  untouched (the child's own location reads stay open, decision 4).
- Gated: `GET /v1/alerts` (`alerts`); the three location reads (`location`); `/v1/social/events`,
  `/v1/content/searches`, `/v1/reports/web` and `/v1/reports/activity` (`social`).
- Embedded copies follow the same rule (decision 2): `GET /v1/family/me` omits `geofences` for a guardian without
  `location`, `GET /v1/devices/:id` omits telemetry `urls` for one without `social`, and
  `GET /v1/reports/summary` omits `topBlockedDomains` while keeping every count.
- The family export is owner-only (decision 6), and the parent push fan-out skips a guardian without `alerts` so
  the gate on `GET /v1/alerts` is not cosmetic (decision 3, first half).
- **Not done:** the realtime half of decision 3. The websocket ticket carries only `familyId`, so there is no
  per-socket role to filter on; that needs the ticket to carry the parent, which is a wire-contract change.
- Tests: 21 rows covering owner/co-parent/guardian-with/guardian-without per gated read, the three embedded fields
  and the push fan-out. Mutant: disabling the gate turns **6** of them red.
