# Changelog

All notable changes to OSRA are recorded here. Format: [Keep a Changelog](https://keepachangelog.com/),
versioning follows the product milestones rather than strict SemVer (this is pre-1.0 software).

Entries are grouped by the day the change landed on `main`, with the PR/issue references that carried
it. Anything marked **⚠️ not verified here** was written by an agent but could not be verified in the
environment where it was written — see `docs/QA/` for the verification state.

---

## [Unreleased]

### Fixed — Issue #45: YouTube Restricted Mode Enforcement Across API, Desktop Agent, and Parent App
- **API Persistence (`services/api`)**: Added `youtubeRestrictedMode` column (`@default("strict")`) to Prisma `RuleSet` model and schema migration `0008_youtube_restricted_mode`. Updated `toRow`, `toApiRuleSet`, and `defaultRuleSetRow` so `PUT /v1/rules/:childId` persists `youtubeRestrictedMode` ("strict" | "moderate" | "off") to PostgreSQL and subsequent `GET` requests return the persisted value. Verified via vitest covering PUT → GET round-trip across all three modes (206/206 passed).
- **Windows Desktop Agent Dynamic Header Selector (`apps/agent-desktop`)**: Added pure header selector `SafeSearch.GetYouTubeRestrictHeaderValue(mode)` mapping `"strict"` → `"Strict"`, `"moderate"` → `"Moderate"`, and `"off"` / unrecognized → `null`. Wired into `RuleSetSnapshot`, `RuleSetMapper.FromDto`, and `WebFilterProxy.cs` so `YouTube-Restrict` HTTP headers are dynamically set based on the active ruleset's `youtubeRestrictedMode` rather than hardcoding "Strict". Added xUnit theory unit tests in `SafeSearchTests.cs` (183/183 passed).
- **Parent App Reload Verification (`apps/parent-app`)**: Verified that when the API returns `youtubeRestrictedMode: 'off'`, `WebFilterRule.fromJson` retains `'off'` and `RulesEditorScreen` properly renders the `SegmentedButton` selected state as `{'off'}` without reverting to `'strict'`. Added regression widget test in `content_safety_test.dart` (103/103 passed, analyze clean).

### Added — Parent App Content Safety Features
- **Search Safety View (`apps/parent-app`)**: Dedicated screen (`/child/:id/searches`, accessible from `ChildDetailScreen` AppBar action) consuming `GET /v1/content/searches?childId=...` (contract: `{ items: [...] }`). Renders flagged search queries with engine glyphs (Google, YouTube, Bing, DuckDuckGo), relative time, severity badges, and concern tags with pull-to-refresh.
- **YouTube Restricted Mode Toggle (`apps/parent-app`)**: Tri-state control (`Strict` / `Moderate` / `Off`) in `RulesEditorScreen` Web Filter tab. Enables parents to configure YouTube restriction levels, synchronizing via `WebFilterRule` to the backend rules API and Windows agent DTO.
- **Snippet Vault Decryption Modal (`apps/parent-app`)**: Reusable `SnippetVaultModal` displaying decrypted content from the AES-256-GCM vault, with encryption trust verification banner, clipboard copy utility, concern tags, and integrated bilingual `CoachCardSection` (EN/عربي). Wired into `SearchSafetyScreen` and `SocialScreen` / `ConcernsSection`.
- **Unit & Widget Test Suites**: Added `apps/parent-app/test/content_safety_test.dart` testing models, `SearchSafetyScreen`, `SnippetVaultModal` (including Arabic/English coaching toggle), `RulesEditorScreen` YouTube mode switching, and `ChildDetailScreen` navigation action. Maintained strict `kSocialApps` 8-app bound as per spec #2.

### Added — CI becomes a real gate
- **`scripts/check-workflows.mjs`** — a dependency-free validator for `.github/workflows/*.yml` that
  catches the traps YAML parsers accept but GitHub rejects (`uses:`+`run:` in one step, `with:` without
  `uses:`, a job without `runs-on:`, tabs) and flags gates that cannot fail (`|| echo`, `|| true`,
  `continue-on-error`).
- **`.github/workflows/workflow-lint.yml`** — runs that validator `--strict` from a *separate* file, so
  it still executes when a sibling workflow file is invalid.
- **`services/ai-engine/requirements-dev.txt`** — test-only dependencies (pytest, fastapi, pydantic,
  httpx). The heavy runtime deps (torch/transformers) stay in `requirements.txt` and are imported
  lazily, so the CI job runs in seconds.

### Fixed — CI
- **`child-android` never actually ran.** The job targeted `runs-on: macos-13`, a runner GitHub has
  retired, so it sat `queued` indefinitely — the Android suite and the `assembleDebug` guard were
  configured but never executed (the same class of failure as #37: a gate that looks present and does
  nothing). Moved to `ubuntu-latest`, which ships the Android SDK and needs no macOS.
- **`api` job green again**: CI never generated the Prisma client (`pnpm install` does not); locally
  `node_modules/.prisma` existed, which hid it. Added an explicit `prisma generate` step before the
  type-check. Symptom was `TS2694`/`TS7006` on every Prisma-touching route.
- **`ai-engine` job green again**: it exited `127` because `pytest` was missing; the job now installs
  the dev requirements (measured: **21 passed**, versus 18 passed + 1 skipped when `fastapi` is absent).
- **Removed the duplicate `child-ios` job** from `ci.yml`. It ran a subtly different
  `xcodebuild test -destination 'platform=iOS Simulator,name=iPhone 15'` and failed on simulator
  availability while the dedicated `ios-ci.yml` passed. One authoritative iOS gate is better than two
  that disagree.
- **`main-guard.yml`**: the last `|| true` was replaced with an explicit `if/else`, so the strict lint
  is meaningful and a genuine failure cannot be silently swallowed.

### Documentation
- `CHANGELOG.md` (this file), `docs/README.md` (documentation index), `docs/TESTING.md` (how to run and
  interpret every suite and gate), and `docs/adr/` (architecture decision records — the reasoning
  behind the decisions, not just the decisions).
- `AGENTS.md`: documentation is now part of the definition of done.

### Verification state at this point
- `qa-probe`: **73 passed · 0 failed · 3 targets · 2 notes** on `main@6818244`.
- CI: `api`, `parent-app`, `agent-desktop`, `ai-engine`, `workflow-lint` green; `child-android`
  (gradle tests + `assembleDebug`) queued at the time of writing.
- **Open by design** (need a human decision, tracked as probe targets): agent-request replay protection
  (`J2`), consent revocation enforcement (`J3`), and the global-secret fallback for devices without a
  per-device secret (`J6` / ask 16).
- **Verified on the physical device (SM-F721B, Android 16, build `main@6818244`)**: the agent no longer
  crashes on first run without location permission (`0` fatals), the location service starts **from the
  permission dialog without relaunching** (`isForeground=true types=0x00000008`), a relaunch of a paired
  app resumes tracking, and location actually reaches the server — `POST /v1/location/ping` → `201` with
  a persisted `LocationPing` row. Issues `#18` and `#38` closed with that evidence.
  *Lesson recorded:* my first two measurements said "no service"; the real cause was a **second**
  permission dialog (notifications) still holding the app behind a modal, so `onResume()` never ran. The
  harness, not the product — worth knowing because a tester will hit the same two dialogs.

---

## [2026-10-13] — P0 batch 2: content safety, screen time, proxy, CI syntax, location

### Security
- **Cross-family content write fixed (`#29`, critical).** `POST /v1/content/search-event` and
  `POST /v1/content/youtube-watch` authenticated the HMAC signature but never bound the body `childId`
  to the signing device, so one family's device could plant a fabricated, alarming search (e.g. a fake
  critical self-harm query) into *another* family's child timeline. Both routes now assert the device's
  own `childId` (and `deviceId` when supplied) and reject mismatches with `400`. Verified live: the
  cross-family call returns `400` and the target family sees nothing.
- **Screen-time accumulation fixed (`#31`).** `screenTimeTodayMinutes` returned only the last telemetry
  window (15 minutes of use read back as `5`) because the API summed a single overwritten Redis snapshot
  while the agent posts per-window deltas. Now accumulated per child/day
  (`usage:child:<childId>:<date>`, 48 h TTL). Verified: three 5-minute reports → **15**.
- **`reset-proxy.bat` completeness (`#32`).** It cleared `ProxyEnable`/`ProxyServer` but left the WinINET
  `Connections\DefaultConnectionSettings` blob pointing at the dead `127.0.0.1:8877`, so some clients
  stayed refused after an agent kill. Both the script and `WebFilterProxy`'s restore path now delete the
  Connections values. Verified functionally on the host.

### Fixed
- **Content-safety fallback coverage (`#30`).** The local self-harm pattern required the literal
  *"how to kill myself"*; *"how can I kill myself tonight"* was not flagged. Regex broadened; verified
  flagged `critical` / `self_harm` with the AI engine offline.
- **`ci.yml` syntax (`#37`).** A step carried both `uses:` and `run:`, so GitHub rejected the whole file
  and **every job was skipped** — `main` had no CI signal. Fixed, and the iOS gates no longer append
  `|| echo "…"` (they could not fail before).
- **Android build (`#33`).** `main` did not compile (`Unresolved reference: PackageManager` in
  `PairingActivity.kt`, introduced by the AND-13 fix itself), so no APK could be produced. Fixed.
- **Location FGS normal flow (`#18`, `#38`).** The agent no longer crashes when location permission is
  missing (it shows a "GRANT LOCATION PERMISSION" step), but in the normal flow the service still does
  not start: `startForegroundCompat()` catches `SecurityException` and returns `false` silently, and
  `showStatus()` never starts the service. Fix work in this batch; **hardware re-verification pending**.

### Added
- Track 1 (content safety) specs and routes: `docs/SPEC-CONTENT-SAFETY.md`,
  `POST /v1/content/search-event`, `POST /v1/content/youtube-watch`, `GET /v1/content/searches`.
- Track 2 (multimodal concern engine) spec: `docs/SPEC-AI-CONCERN-ENGINE.md`; Android monitored apps
  expanded to 10 (YouTube, YouTube Kids, Telegram, Reddit, Messenger join WhatsApp/Instagram/TikTok/
  Snapchat/Discord/Roblox).
- Headless iOS CI: `.github/workflows/ios-ci.yml` (SwiftPM build + `generic/platform=iOS Simulator` on
  `macos-14`), plus `docs/test-guides/IOS-CI-TESTING.md`.

---

## [2026-10-11 → 2026-10-12] — QA discipline, P1 batch, and the AI/content tracks

### Added
- **Adversarial acceptance gate** `services/api/scripts/qa-probe.mjs` — 70+ checks that try to *break*
  the documented invariants (family isolation, per-device HMAC, consent gate, revocation, token
  hygiene, input bounds, error hygiene, alert-category coverage). Exits non-zero while findings are
  open; the collaboration contract treats it as the merge gate.
- **Collaboration protocol** `AGENTS.md`: roles (implementation vs verification), definition of done,
  PR-only `main`, restatement-first pull requests, point-by-point evidence-based review, `needs-human`
  escalation, and device/environment hygiene.
- **Discussion log** `docs/QA/DISCUSSION-LOG.md` and the PR template
  `.github/PULL_REQUEST_TEMPLATE.md`.
- **Five platform audits** (`docs/QA/audits/`) and the consolidated `docs/QA/QA-REPORT-*.md`:
  48 findings with `file:line` evidence.
- **`/health/deep`** — readiness probe reporting `db`/`redis`, so an outage that leaves `/health` green
  can be diagnosed in one request.
- **Device/environment hygiene rule** (`AGENTS.md` §7) and
  `services/api/scripts/cleanup-test-data.sql` (dry-run by default).

### Fixed
- P1 batch: Android counter persistence / fail-closed rules / overlay bypasses (`#6`–`#8`), Flutter↔API
  contract mismatches and the refresh race (`#13`), Windows overlay/rename/screen-time issues (`#9`–`#11`),
  iOS shielding compile errors and store isolation (`#14`), plus `alwaysAllowedApps` round-tripping.
- API P0 bundle (`#1`–`#5`): per-device secrets no longer leak into parent payloads (an
  allowlist-by-omission bug), the iOS alert shape is accepted, the four previously-dropped alert
  categories work, cross-child injection is blocked, and device revocation applies to every route.
- `prisma generate` is required for type-checking (documented in CI).

### Infrastructure
- PostgreSQL runs as the auto-start Windows service `OSRA-Postgres` (immune to console/session reaping).
- `main` is PR-only. Branch protection is unavailable on free private repos, so the rule is enforced by
  `.githooks/pre-push` (verified) plus server-side detection in `main-guard.yml`; `main` was later made
  public, which allowed real branch protection to be switched on.

---

## [2026-09-18 → 2026-09-19] — Review response and token hygiene

### Security
- **Per-device HMAC secrets** replace the single shipped secret: a device receives its own secret once
  at pairing; the server verifies agent alerts against that device's key, and the global
  `INTERNAL_HMAC_SECRET` remains only as the AI-engine fallback.
- **Token hygiene**: refresh tokens rotate with reuse detection (a replayed token revokes the parent's
  sessions), `/logout` and `/logout-all`, revocation on password reset and MFA enable, device-token
  revocation on unpair, and single-use WebSocket tickets (`POST /v1/ws-ticket`) so JWTs never appear in
  URLs.
- MFA (TOTP) is optional and off by default; it is enforced only when a parent enables it, and TOTP
  replay fails closed in production when Redis is unavailable.
- Consent gate (HTTP 428) enforced at child creation; family isolation (403) on every data route.

### Fixed
- Wellbeing URL mismatch (the app called `/v1/wellbeing/:id`, the API served `/v1/reports/wellbeing/:id`).
- App Insights endpoint implemented instead of returning 404.
- Cross-platform pairing fixes: the child agent accepts LAN URLs without a scheme; the parent app
  normalises them the same way.
- **Server URL fields start blank** in every client (parent, child, Windows, iOS) — no pre-filled default
  that could point at a stale or built-in address.
- Android child agent: cleartext HTTP allowed for LAN test servers via a test-only network security
  config.

### Added
- First cross-platform artifacts in `dist/` (parent APK, child agent APK, Windows agent) and the
  tester-facing guides (`docs/test-guides/`).

---

## [2026-09-14 → 2026-09-16] — MVP and the world-class feature set

### Added
- Monorepo: Flutter parent dashboard, Kotlin Android agent, Swift iOS agent, .NET 8 Windows agent,
  Fastify/Prisma API, FastAPI AI engine, shared packages (types, consent SDK, crypto), infra templates.
- 29 "world-class" features: default-on 13-category protection, pause internet, WhatsApp/social AI
  monitoring with an encrypted snippet vault, calls & SMS timeline, install alerts with one-tap block,
  always-allowed apps, bonus time, wind-down, child SOS, multi-parent invites, tamper & VPN alerts,
  usage reports, wellbeing score, live activity chip, app insights, digest preferences, conversation
  coach (EN/عربي), routines, geofences, ring/lock/unlock.
- Seed data (demo family, child "Alex", device "Pixel 7a") and the live end-to-end suite
  `services/api/scripts/e2e.mjs` (50 checks).

<!--
When you add an entry:
1. Put user-visible changes under Added/Changed/Fixed/Removed/Security for the current release heading.
2. Reference the PR or issue number.
3. If something could not be verified where it was written, say so explicitly — an unverified claim in a
   changelog is worse than no changelog. `docs/TESTING.md` explains how each claim is checked.
-->
