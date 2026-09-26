# Competitive analysis — FamilyShield vs Qustodio vs Google Family Link

Target: feature parity or better for the Android + Windows test scope. Legend:
✅ shipped & QA-verified · 🟡 partial/test-build limited · ❌ not yet (roadmap)

## Core control

| Feature | Qustodio | Family Link | FamilyShield |
|---|---|---|---|
| Daily screen-time limit | ✅ | ✅ | ✅ Android + Windows (weekend variant) |
| Per-app time limits | ✅ | ✅ | ✅ both platforms (desktop kills + alerts) |
| Scheduled routines (school, homework) | ✅ | ✅ (school time) | ✅ Android; ✅ desktop (added in QA) |
| Bedtime window | ✅ | ✅ | ✅ Android blocks; desktop `LockWorkStation` |
| Pause device (instant) | ✅ | ✅ (lock now) | ✅ added (pause/resume, all platforms) |
| Lock / unlock remotely | ✅ | ✅ | ✅ PIN-overlay on Windows; overlay/owner-lock on Android |
| Locate / ring device | ✅ | ✅ | ✅ ring + locate_now |
| SOS / panic button (child side) | ✅ | ❌ | ❌ alert category exists; no child UI — roadmap |

## Web & content

| Feature | Qustodio | Family Link | FamilyShield |
|---|---|---|---|
| Category web filter | ✅ | ✅ | 🟡 HTTP only (HTTPS needs root CA install) |
| Custom allow/block lists | ✅ | ✅ | ✅ |
| SafeSearch enforcement | ✅ | ✅ | ✅ (google/bing/youtube rewrite, dedup-safe) |
| YouTube Restricted Mode | ✅ | ✅ | 🟡 HTTP search rewrite only; HTTPS YouTube not enforceable without MITM |
| Blocked-site alerts | ✅ | ✅ | ✅ `web_threat` alerts (throttled) |

## Monitoring & reports

| Feature | Qustodio | Family Link | FamilyShield |
|---|---|---|---|
| App usage report | ✅ | ✅ | 🟡 collected (15-min telemetry); no report UI yet — roadmap |
| Browsing history report | ✅ | ✅ | 🟡 url_log → telemetry; no report UI yet — roadmap |
| Daily/weekly email reports | ✅ | ✅ | ❌ roadmap (needs mail infra) |
| Real-time alerts (AI content) | ✅ | 🟡 | ✅ pipeline + AI engine (fallback classifier) |
| Call/SMS monitoring | ✅ | ❌ | ❌ roadmap |

## Location

| Feature | Qustodio | Family Link | FamilyShield |
|---|---|---|---|
| Live location | ✅ | ✅ | ✅ (adaptive ping, map needs API key) |
| Geofences enter/exit | ✅ | ✅ | ✅ with transition alerts |
| Location history | ✅ | ✅ | ✅ API exists; UI list roadmap |

## Family & compliance

| Feature | Qustodio | Family Link | FamilyShield |
|---|---|---|---|
| Multi-parent / co-parenting | ✅ | ✅ | 🟡 schema supports it; invite flow roadmap |
| COPPA/GDPR-K consent gate | ✅ | ✅ | ✅ hard 428 gate + consent SDK |
| GDPR export / erasure | ✅ | ✅ | ✅ JSON export + cascade delete |
| Offline tolerance | ✅ | ✅ | ✅ Room/SQLite buffers + flush-on-reconnect |
| Platforms | 5+ | Android/Chromebook/iOS | Android + Windows now; iOS spec'd (Screen Time) |

## Where we're ahead

- Verifiable parental consent as a **hard API gate** (428) with an evidence-carrying SDK.
- HMAC-signed agent channels + per-family data isolation proven by tests (403 matrix).
- AI content analysis pipeline (on-device → alerts) wired end-to-end; fallback classifier
  works without ML infra.
- Fully self-hostable backend (docker-compose or portable binaries).

## Prioritized roadmap (from this matrix)

1. Activity/report UI (usage + browsing history screens) — data already collected.
2. HTTPS filtering with optional root-CA install (closes the biggest gap).
3. Child-side SOS button (Android quick tile + desktop hotkey).
4. Report persistence for url_log/app usage server-side (DB tables) + weekly digest.
5. Multi-parent invitations, more platforms (iOS agent + macOS).
