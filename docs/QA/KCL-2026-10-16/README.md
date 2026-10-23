# KCL assessment — 2026-10-16

Independent readiness assessment of OSRA against Qustodio Premium / Google Family Link,
performed on branch `KCL` cut from `main@fe1997c`. Read-only: no application code was changed.

The full write-up (verdict, scorecard, feature reality check, WhatsApp analysis, platform
constraints, branch/PR review incl. PR #48, five-phase plan, decisions needed) is the
"OSRA Readiness Assessment & Plan" doc shared with the maintainer. This folder holds the raw,
file:line-cited audits that the doc summarises:

| File | Scope | Rating /10 |
|---|---|---|
| `AUDIT-ANDROID.md` | `apps/child-android` — lock, find, ring, blocking, social, comms, VPN, tamper, push, SOS, onboarding, build | 3 |
| `AUDIT-IOS-WINDOWS-MACOS.md` | `apps/child-ios`, `apps/agent-desktop`, `apps/agent-macos`, store readiness | 2 / 4 / 0 |
| `AUDIT-API-AI-PARENT-APP.md` | `services/api`, `services/ai-engine`, `apps/parent-app` | 4 / 2 / 4 |
| `COMPETITOR-LANDSCAPE.md` | Qustodio, Family Link, Bark, Apple, MS, Norton, Kaspersky, Aura, MMGuardian; Play/Apple policy constraints | — |

## Headline findings

1. No device admin on Android: uninstall, clear-data, and an unauthenticated **Re-pair** button
   (`PairingActivity.kt:273-283`) each remove protection in seconds.
2. No push notifications to parents (`alerts.ts:49-53` is `console.log`); no email provider.
3. AI engine ships as ~12 English regexes — no model checkpoint in repo, compose path unmounted,
   tests force the fallback (`model.py`, `docker-compose.yml:14-18`, `tests/conftest.py:8`).
4. iOS: SwiftPM library only — no Xcode target, entitlements or extension targets; `ScreenTimeController`
   has zero callers; no rule/command sync.
5. Pause-internet / web filter on Android is an overlay + RAM flag; no `VpnService`.
6. Lock is a dismissable overlay (Recents swipe, reboot); device-owner branch is dead code.
7. FCM not configured on the device (no `google-services.json`); 60 s / 15 min polling in practice.
8. Usage "today" lives in Redis with 24–48 h TTL; no rollup tables; erasure leaves orphans.
9. Nothing is store-signed; parent app release manifest lacks `INTERNET`; no Maps API key.

## PR #48 (`fix/43-consent-revocation`) — Request changes

Clean implementation, green CI, but the gate points the wrong way: after revoke, device ingestion
(`/v1/location/ping`, `/v1/social/scan`, `/devices/:id/telemetry|activity`, `/alerts/internal`,
`/content/*`) and device reads (`GET /v1/rules/:childId`, `GET /devices/:id/commands`) remain open,
while safe-direction parent actions (`resume`, `resume-internet`, `wind-down`) are blocked and
`POST /devices/:id/command` (lock/ring/locate) is not. Details and the fix list are in the doc.

## Branches

19 of 21 remote branches are fully merged into `main` and can be deleted. Unmerged:
`fix/43-consent-revocation` (PR #48) and `qa/verify-track12-2026-10-12` (PR #34 notes, superseded by #36).
