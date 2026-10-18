# OSRA — Engineering & QA Collaboration Hub

> **Superseded (2026-10-17).** Historical record of the pre-KCL setup; keep it for the trail, do not
> work from it. Roles are `AGENTS.md` §1, the roadmap and documentation rules §12, the `state:*`
> work-state labels §10 and the identity convention §11; the plan is `docs/ROADMAP.md` and the
> board `docs/QA/TEST-REQUESTS.md`. The role split and the `ANTIGRAVITY` branch below no longer apply.

**Co-Engineered by Antigravity (Dev & Architecture) & Kimi (Testing & QA)**
*Git Branch:* `ANTIGRAVITY` | *Target:* Feature Parity & Market Leadership over Qustodio Premium & Google Family Link

---

## 1. Collaboration Protocol (Antigravity 🤝 Kimi)

| Role | Agent | Primary Responsibilities |
|---|---|---|
| **Development & Architecture** | **Antigravity** | Code implementation, architectural design, library upgrades, bug fixing, test suite maintenance, builds & compilations. |
| **Testing & Quality Assurance** | **Kimi** | Test plan execution, edge case identification, penetration & circumvention testing, verification of fixes, feedback reporting. |

### Handover & Sync Workflow:
1. **Defect Handoff**: Kimi logs discovered issues in the **Active Defect Registry** below with severity, reproduction steps, and platform.
2. **Implementation**: Antigravity addresses the defects, commits fixes to the branch, and documents the code changes.
3. **Verification**: Kimi executes test scripts against the updated code to verify resolution and attempts bypass attacks.
4. **Roadmap Execution**: Both agents align on each milestone phase before advancing.

---

## 2. Active Defect Registry (Identified by Initial Inspection)

| ID | Component | Severity | Description | Status |
|---|---|---|---|---|
| **BUG-001** | `services/api` & `child-android` | **Critical** | **Location Ping Schema Break**: Android posts `{"pings": [...]}` batch while API expects a flat single object with mandatory `childId`/`deviceId`. All pings fail with HTTP 400. | Fixed in PR #21 (`main`) |
| **AND-13** | `child-android` | **Critical** | **Android 14+ FGS Crash-Loop**: `LocationService` throws `SecurityException` on missing permissions, crash-looping under `START_STICKY`. | Fixed in PR #21 (`main`) |
| **BUG-002** | `services/api` & `child-android` | **Critical** | **Screen-Time 60x Multiplier**: Android sends cumulative total in 60s heartbeats; server sums all rows, inflating 30 min into 15+ hours. | Fixed (`fix/p1-flutter-api-contracts`) |
| **BUG-003** | `services/api` | **Critical** | **Rejected Security Alerts**: `InternalAlertSchema.category` rejects `tamper`, `vpn_detected`, `install_request`, `unknown_contact`, and `social_concern` (HTTP 400). | Fixed in PR #20 (`main`) |
| **BUG-004** | `services/api` | **High** | **`alwaysAllowedApps` Wiped**: Zod schema strips `alwaysAllowedApps` on PUT/PATCH, deleting whitelisted apps on every rules save. | Fixed in PR #20 (`main`) |
| **BUG-005** | `parent-app` & `services/api` | **Medium** | **Pending Invites UI Blank**: API returns `{ invites: [...] }` while Flutter provider looks for `items`, permanently showing "No pending invites". | Fixed (`fix/p1-flutter-api-contracts`) |
| **BUG-006** | `services/api` | **High** | **Stale Family JWT on Invite Accept**: Co-parent accepts invite but receives no new JWT; subsequent calls use the old family ID (HTTP 403). | Fixed (`fix/p1-flutter-api-contracts`) |
| **FLT-01** | `parent-app` | **High** | **Concurrent 401 Refresh Race**: Multiple parallel 401s race token refresh and trigger session revocation / forced logout. | Fixed (`fix/p1-flutter-api-contracts`) |
| **FLT-04** | `parent-app` | **High** | **GoRouter Restored Session Stranded**: Router lacked `refreshListenable`, stranding restored sessions on `/login`. | Fixed (`fix/p1-flutter-api-contracts`) |
| **FLT-06** | `parent-app` & `services/api` | **High** | **Location History Timestamp Discrepancy**: History parsed `ts`, API returned `timestamp`; today's route empty. | Fixed (`fix/p1-flutter-api-contracts`) |
| **BUG-007** | `agent-desktop` | **Critical** | **Windows HTTPS Filtering Bypass**: Titanium proxy only hooks `BeforeRequest`; all HTTPS `CONNECT` tunnels bypass web filtering without root CA MITM. | Ready for Fix (P1) |
| **BUG-008** | `child-android` | **High** | **Reboot Screen-Time Counter Reset**: `UsageCounters` stores daily usage in an in-memory map; restarting the phone resets usage to 0. | Ready for Fix (P1) |
| **BUG-009** | `child-android` | **High** | **SOS Missing GPS Coordinates**: SOS emergency alert payload omits GPS coordinates. | Ready for Fix (P1) |
| **BUG-010** | `child-ios` | **High** | **iOS Alert Signature Mismatch**: `AlertReporter` omits `deviceId`, causing the server to reject HMAC verification with HTTP 401. | Fixed in PR #20 (`main`) |
| **BUG-011** | `services/api` | **Medium** | **Cross-Child Location Spoofing**: `POST /ping` with HMAC authentication does not verify that `deviceId` belongs to `childId`. | Fixed in PR #20 (`main`) |

---

## 3. Best-in-Class Technology Stack & Library Audit

To outperform Qustodio and Google Family Link, we must ensure each component leverages optimal, modern libraries:

### A. Backend API (`services/api`)
* **Core Framework**: Fastify 4.x + TypeScript (Kept — 3-4x faster than Express, ideal for high-throughput agent heartbeats).
* **Database & ORM**: PostgreSQL 16 + Prisma 5 (Kept — highly maintainable, strong typing).
* **Push Notifications**: **Upgrade Required** — Replace stubbed `[push:stub]` with `firebase-admin` (FCM v1 API) for background push alerts to parents.
* **Background Job Queue**: **Addition Needed** — Add `bullmq` with Redis for reliable scheduled tasks (midnight counter reset, weekly summary digests, stale data pruning).
* **Real-time Bus**: Redis Pub/Sub + `@fastify/websocket` (Kept — single-use ticket mechanism is sound).

### B. AI Safety Engine (`services/ai-engine`)
* **Framework**: FastAPI + Pydantic v2 (Kept).
* **NLP Pipeline**: **Upgrade Required** — Current DistilBERT and regex rules are English-only.
  * Add multilingual semantic concern classification (`aubmindlab/bert-base-arabizi` or `xlm-roberta-base`).
  * Introduce Arabic and Franco-Arabic (Arabizi) regex rules for self-harm, cyberbullying, grooming, and substance abuse to serve the Middle Eastern family demographic (OSRA / أسرة).
  * Optional Gemini 1.5 Flash API connector for deep contextual nuance in flagged social threads.

### C. Android Child Agent (`apps/child-android`)
* **Architecture**: Kotlin 1.9, Dagger Hilt, Room, Retrofit, Kotlin Coroutines & Flow (Kept — clean modern architecture).
* **Web Filtering & SafeSearch**: **Major Addition Needed**
  * Current: Only app-level blocking exists; browsers are completely unfiltered.
  * Solution: Implement an embedded Android `VpnService` with a local loopback DNS proxy (inspecting port 53 DNS queries) to block domain categories and rewrite Google/Bing/YouTube queries to SafeSearch VIPs without requiring root certificates.
* **Tamper Protection**: **Major Addition Needed**
  * Current: Standard user app; can be uninstalled from Settings in 3 seconds.
  * Solution: Integrate `DeviceAdminReceiver` (`DevicePolicyManager`) to lock uninstallation with parent authentication.
* **Foreground Tracking**: Integrate `UsageStatsManager` with `AccessibilityService` for persistent foreground tracking resistant to process kills.

### D. Windows Desktop Agent (`apps/agent-desktop`)
* **Runtime**: .NET 8 (C#) (Kept — self-contained, high performance).
* **Web Filtering Engine**: Titanium.Web.Proxy (Kept — excellent performance).
  * **Fix**: Hook `BeforeTunnelConnectRequest` to inspect SNI on HTTPS connections and block categories without requiring root CA certificates.
* **Service Deployment**: **Upgrade Required**
  * Switch from user-space executable to a Windows Service (`Microsoft.Extensions.Hosting.WindowsServices`) running under `NT AUTHORITY\SYSTEM`.
  * Add watchdog recovery so kids cannot terminate it via Task Manager.
  * Configure GPO registry locks (`ProxySettingsPerUser = 0`) to prevent proxy tampering.

### E. Flutter Parent Dashboard (`apps/parent-app`)
* **Framework**: Flutter 3.x, Flutter Riverpod 2.5, Dio, GoRouter (Kept — responsive, cross-platform).
* **State & Sync**: WebSocket real-time updates + Riverpod (Kept).
* **Push Integration**: Add `firebase_messaging` and `flutter_local_notifications` to receive instant SOS, tamper, and geofence alerts.
* **Localization**: Full RTL Arabic (العربية) and English support across all dashboard screens.

---

## 4. Product Roadmap: Winning Against Qustodio & Family Link

```
┌────────────────────────────────────────────────────────────────────────┐
│ Phase 1: Operational Stability & Core Integrity (Fix BUG 001 - 011)   │
└───────────────────────────────────┬────────────────────────────────────┘
                                    ▼
┌────────────────────────────────────────────────────────────────────────┐
│ Phase 2: Fortress Tamper Resistance & True Web Filtering              │
│ - Android Device Administrator (Uninstall Lock)                       │
│ - Android Local DNS VPNService (Browser Domain Filter + SafeSearch)   │
│ - Windows Service Mode (Task Manager Protection) + HTTPS SNI Blocking │
│ - Firebase Admin FCM Push Integration                                 │
└───────────────────────────────────┬────────────────────────────────────┘
                                    ▼
┌────────────────────────────────────────────────────────────────────────┐
│ Phase 3: Market Superiority Features (Beating Competitors)             │
│ - Cross-Device Shared Screen-Time Budget (Unified Daily Pool)         │
│ - Bilingual (Arabic + English) AI Social Safety Engine                │
│ - Pre-Approval Workflow for New App Installs                          │
│ - Live Battery Percentage & Low Battery (<15%) Push Alerts            │
│ - Incoming Call & SMS Blocker for Unapproved Contacts                 │
│ - YouTube Watch & Search History Extraction                           │
└────────────────────────────────────────────────────────────────────────┘
```

---

## 5. Next Action Steps

1. **Antigravity Action**: Execute Phase 1 bug fixes across `services/api`, `apps/child-android`, `apps/agent-desktop`, and `apps/parent-app`.
2. **Kimi Action**: Review this roadmap, conduct testing sweeps against the fixes, and log bypass attempts or regression findings in Section 2.
