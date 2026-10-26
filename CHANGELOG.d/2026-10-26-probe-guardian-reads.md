### Probe — a guardian is refused the alert, location and social reads, and the export is owner-only (plan 2.7)
- New `Q6e` follows the ADR-0014 amendment (#399), as built in #401. A guardian invited with no permissions is
  refused each of the eight gated reads with `403 permission_required` naming the permission: `alerts`, the
  three location reads, and the social events, searches, `/reports/web` and `/reports/activity` reads. The
  broad reads hold the same data back: `/v1/family/me` has no `geofences` and `/v1/reports/summary` has no
  `topBlockedDomains`.
- `Q6c` (the guardian) now walks only the 15 reads a guardian keeps. `Q6d` (the co-parent) walks all 23,
  because the amendment doesn't change co-parents.
- `GET /v1/family/export` is owner-only (#326). It moved from Q6c/Q6d to Q6/Q6b, which expect
  `403 owner_role_required`.
- `docs/QA/security/authz-matrix.md`: the guardian column gives `403p:<perm>` on the gated reads and both
  roles give `403o` on the export. The legend has the guardian-read rule, and §1a cites Q6e and
  `t:guardian-reads.test.ts`.
- Measured against #401's head `1fdbc85` on a local stack: 194 passed, 0 failed, 0 x 429. Mutant (the gate
  removed from `GET /v1/social/events`, and the geofence omission turned off): 193/1. Q6e names both. Against
  `main` before #401, Q6e fails by design, so this merges after #401.
