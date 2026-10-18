# ADR-0020 — The family's timezone comes from the parent's device and is a parent setting; `region` stays a market

**Status:** accepted
**Date:** 2026-10-18
**Deciders:** Claude (architecture), on work order C1 in #92 (Kimi, development lead); roadmap 2.2 follow-up / 3.x

## Context

ADR-0017 makes the digest due at the family's local hour and #93 adds `Family.timezone` (IANA, default
`UTC`). Nothing writes that column yet, so every family is still on UTC, and a Dubai family still gets its
"evening" digest at 22:00. #93's ADR amendment records issue **B1**: the obvious source, `Family.region`, can't
supply a zone, because it is a market (`z.enum(["US", "EU", "UK", "OTHER"])`, `services/api/src/routes/auth.ts:18`),
not a country.

`region` also carries legal weight. It selects the consent jurisdiction (`checkActiveConsent(child.id,
child.family?.region)`, `services/api/src/routes/devices.ts:123`), and `family.ts:113` rejects a consent
whose jurisdiction doesn't match it (the COPPA / GDPR-K gate, spec §12.5). Any change to what `region` means
is therefore a change to who must give consent and how.

## Decision

1. **B1: `region` is not extended.** It stays a market and jurisdiction value. Timezone is a separate fact
   with its own column (`Family.timezone`, from #93).
2. **Source at signup.** `POST /v1/auth/register` accepts an optional `timezone`. The parent app sends the
   device's zone (`DateTime.now().timeZoneName` is not enough because it gives an abbreviation; use the
   `flutter_timezone` value, or `Intl.DateTimeFormat().resolvedOptions().timeZone` on web). The server
   stores it only if `isValidTimeZone()` (`src/lib/digestSchedule.ts`) accepts it, and otherwise keeps `UTC`.
3. **A parent setting.** `PATCH /v1/family/me { timezone }` (parent role, the same validation), shown in the
   parent app's family settings as a zone picker that is pre-filled with the current value. This is the 3.x
   app work. The API half lands with step 2.
4. **Existing families get one automatic fill, never an override.** Add `Family.timezoneSource`
   (`default` | `device` | `parent`, default `default`). On a parent login that sends a valid zone, the
   server sets `timezone` and `timezoneSource = device` **only while the source is `default`**. A parent's
   explicit choice (`parent`) is never replaced by a device value, so a parent travelling abroad doesn't
   move the family's digest.
5. **Until step 2 ships, UTC is correct.** It is the documented default, not a bug: the digest arrives at
   18:00 UTC, as it did before #93.

## Alternatives considered

- **Extend `region` to ISO-3166 country codes** (B1 option 1). Rejected:
  - It changes the consent jurisdiction semantics described above, so it would need a migration of every
    family's consent records.
  - A country doesn't determine a zone. The US has six, Russia eleven, and Egypt has observed DST in some
    years and not in others.
- **Derive the zone from the child's device.** Rejected:
  - A family can have several children and devices in different places.
  - A child's device is the less trusted side (it's the device under control).
  - It would add a new data flow from the child, which needs its own privacy justification.
- **IP geolocation at signup.** Rejected: it's wrong behind VPNs and carrier NAT, and it adds a third-party
  lookup of personal data for a convenience.
- **Per-parent timezone.** Rejected for now: the digest is per family, and two parents in two zones is rare.
  It can be added later without breaking this, because the family value would stay the default.

## Consequences

- Good: new families get the right hour with no extra step, and existing families correct themselves on the
  next parent login.
- Good: `region` keeps one meaning, so the consent gate is untouched.
- Cost: one more column (`timezoneSource`) and one more rule in the login path. Tests, named as the rule:
  - `login fills timezone from the device while timezoneSource is default`;
  - `login never overwrites a timezone the parent chose` and `a second device login does not move a
    device-filled zone` (the update is conditional on `timezoneSource = 'default'`, in the same statement,
    not read-then-write);
  - `an invalid or absent timezone leaves the family unchanged` (the field is optional and additive, so
    existing clients send nothing and nothing changes).
- Cost: a family whose parents never log in again stays on UTC. That is acceptable; it's the behaviour
  before #93.
- Risk: the device zone is a **coarse, weak signal**. A VPN, a flight or a parent signing up abroad changes
  it. It's used only to choose a send hour, and must never be treated as location or identity. The settings screen in step 3 is the
  correction, and the digest email footer should name the zone it uses ("sent at 18:00 Asia/Dubai").

## Not decided here

- Quiet hours and schedules in the child agent use the **device's** local clock, not `Family.timezone`. This
  ADR doesn't change that.

## Amendment 2026-10-18 (correction)

The test wording in the first amendment said the fill is conditional on `timezoneSource <> 'parent'`. That
contradicts decision 4 and was my error. With that guard, every parent login re-fills the zone from whichever
device logs in, so a parent travelling abroad moves the family's digest, which is exactly what decision 4
rules out. The guard is `timezoneSource = 'default'`: the device fills a family once, and only the parent's
setting changes it after that.
