# ADR-0017 — The weekly digest is sent at the family's local hour

**Status:** accepted
**Date:** 2026-10-17
**Deciders:** Claude (architecture), on the open item raised by Kimi (development lead) on #50; roadmap 2.2 / 3.x

## Context

Plan 2.2 shipped the weekly digest at `DIGEST_HOUR_UTC` (default 18:00 UTC, Sunday) from
`src/jobs/digestScheduler.ts`. The roadmap records the gap: there is no per-family timezone, only
`Family.region`, so a Dubai family gets its "evening" digest at 22:00. OSRA's first markets are the Gulf
and Egypt, where the hour matters. The parent app has no timezone setting yet (that is 3.x).

## Decision

1. Add `Family.timezone` (IANA name, `NOT NULL`). The migration backfills it from `Family.region`:
   `AE`→`Asia/Dubai`, `SA`→`Asia/Riyadh`, `EG`→`Africa/Cairo`, `KW`→`Asia/Kuwait`, `QA`→`Asia/Qatar`,
   `BH`→`Asia/Bahrain`, `OM`→`Asia/Muscat`, `JO`→`Asia/Amman`, anything else→`UTC`. The API validates
   writes against `Intl.supportedValuesOf('timeZone')`.
2. `DIGEST_HOUR_UTC` becomes `DIGEST_HOUR` (local hour, default 18). The scheduler wakes **every hour on
   the hour** and selects families whose local day is Sunday, whose local hour is at or past
   `DIGEST_HOUR`, and that have no send recorded for this week.
3. Idempotency: a `DigestSend(familyId, isoWeek)` row with a unique key is written in the same transaction
   that queues the send. A restart, a duplicate scheduler or a DST repeat hour cannot send twice; a DST
   skipped hour sends at the next hour, because the selection is "at or past", not equality.
4. The parent app sets the timezone in 3.x (settings, pre-filled from the phone). Until then the backfill
   is the value.

## Alternatives considered

- **Keep UTC and let the parent pick an hour in UTC.** Rejected: pushes timezone arithmetic onto parents.
- **Derive the zone from the child's last `LocationPing`.** Rejected: children travel, fixes can be off,
  and the digest follows the parent's week, not the child's GPS.
- **One cron per timezone.** Rejected: one hourly wake with a query covers every zone, including
  half-hour zones, with one job.

## Consequences

**Good.** Each family gets its digest at the same local evening hour, DST included, and never twice.
**Bad, and accepted.** An hourly job instead of a weekly one; one more table; families outside the mapped
regions stay on UTC until the 3.x setting ships.

## Acceptance (for the implementing PR)

Clock fixed at Sunday 14:00Z: the Dubai family sends (18:00 local), the UTC family does not. At 18:00Z the
UTC family sends and Dubai does not resend. Re-running either hour sends nothing. A unit test covers the
DST repeat and skipped hours for `Africa/Cairo`.

## Amendment 2026-10-18 — implementing it (Kimi), and the one defect found in review

**B1: there is no country to backfill from.** The decision above backfills `Family.timezone` from
`Family.region` using country codes (`AE`, `SA`, `EG`, …). Review of this ADR found that `region` is a
**market**, not a country: `packages/shared-types/src/index.ts` types it `"US"|"EU"|"UK"|"OTHER"` and
`services/api/src/routes/auth.ts` validates the same enum, so every existing row falls to the fallback.
The backfill is therefore `UTC` **by construction**, not by accident; migration
`0014_family_timezone_digest_send` says so in its first line, and the 3.x app setting remains the real
source. Extending `region` to ISO-3166 codes is a separate decision with its own migration and copy
changes — it is not smuggled in here.

**B2: the ISO week is the family's local week.** `isoWeekKey` is computed from the family's local
calendar date (`services/api/src/lib/digestSchedule.ts`), not from UTC, so a Sunday 22:00 Dubai send and
the following Sunday 18:00 UTC send cannot land in different weeks. The unique
`DigestSend(familyId, kind, period)` key is only as good as the period it stores.

**What shipped instead of Redis claims.** The previous scheduler claimed each (family, kind, date) with a
Redis `SET NX`. The implementation writes a `DigestSend` row before the email and treats its unique key as
the claim — the ADR asks for "the same transaction that queues the send", and a row survives a Redis
flush. A provider refusal deletes the row so the next tick can retry; a duplicate key means the period is
done.

**Acceptance, as run.** `services/api/test/digest-schedule.test.ts` fixes the clock and asserts: 14:00Z
Sunday → Dubai sends at 18:00 local while UTC does not; 18:00Z → UTC sends and Dubai resolves to the same
weekly period (no resend); a London spring-forward that deletes local hour 01 still sends at 02; a
fall-back repeated hour resolves to one period; 31 Dec and 1 Jan share one ISO week; and the scheduler
claims `(familyId=…, kind=daily, period=2026-10-14)` in the database while a `P2002` duplicate is skipped.
