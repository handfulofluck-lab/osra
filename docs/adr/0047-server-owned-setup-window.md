# ADR-0047: Server-owned initial-setup window for tamper alerts

Status: accepted

## Context

Issue #1127 found that a parent can receive repeated “Protection tampered with” pushes while still granting the permissions a newly paired Android phone needs. A quiet period must not become a child-controlled bypass. Android already reports grant states and tamper types; ADR-0034 makes the server retain that report with a server receipt timestamp. ADR-0027 previously rejected a general time delay for tamper alerts because delayed security evidence is dangerous. This decision is a narrow exception for first setup, not a general throttle.

## Decision

1. `Device.setupCompletedAt` is server-owned and nullable. A new pairing starts incomplete. Migration 0046 backfills existing paired devices complete and emits no alerts; pending pairings remain incomplete. The setup window starts at `pairedAt`, the first request authenticated as that device, and closes at completion or exactly 30 minutes later. Pending devices and events with no trustworthy setup state fail visible.
2. Android setup is complete only when an authenticated telemetry report explicitly marks all seven required grants `granted`: accessibility, usage access, overlay, device admin, web filter, location and private DNS. Missing or `not_applicable` required keys are incomplete. Battery, USB debugging and notification listener remain recommended and do not block completion. The unauthenticated pair-claim snapshot and stale stored reports cannot complete setup. Other platforms are outside this Android-first decision.
3. During the open window, the server holds only a tamper event whose exact type maps to a grant currently reported `missing`: `accessibility_off` and `accessibility` → accessibility; `device_admin_removed` → device admin; `content_filter_disconnected` → web filter; `overlay_revoked` → overlay; `usage_access_off` → usage access; `notification_listener_off` → notification listener. Unknown types, SOS, `vpn_detected`, `private_dns_bypass`, protection-screen/PIN/block-bypass events, app removal/replacement, reinstall/data clear, clock/time-zone changes and safe mode remain visible. Category alone never qualifies.
4. A held event is persisted with `Alert.heldDuringSetup=true` and a `held|`-prefixed dedupe key, returns the normal 201/200 dedupe response, and produces no realtime event or push. It is excluded from parent alert lists/counts, acknowledgement and family export. Held rows remain audit-only after the window closes; they are not released later. The separate key namespace ensures a real event after completion/expiry with the producer's original key creates a new visible, published and pushed row rather than deduplicating the held one.
5. The first authenticated complete report performs one guarded completion transition and emits one deduped `setup_complete` alert. The existing five-minute device-silence runner and the next authenticated command poll share one deduped `setup_incomplete` evaluation at the 30-minute boundary, including with `JOBS_ENABLED=0`. The timeout uses the last stored grant report to name missing steps, or generic incomplete copy when none exists. Later completion may emit the protected alert after the incomplete alert.
6. The approved `dataCleared` pair-claim path remains visible and emits its one existing named `agent_data_cleared` alert. The new Device row starts a fresh incomplete window. No Android local setup clock or hold queue is added.
7. While setup is incomplete, the parent Phone setup section uses the server’s existing `missing` list for “N steps left”; after completion it returns to the existing grant-repair presentation. Completion and incomplete alerts use validated body keys and localized parent titles. Lock-screen bodies remain generic.

## Reasoning

The server already has the authenticated device identity, pairing instant, grant report and alert dedupe boundary. Reusing them avoids a second client-owned flag and works for direct-alert producers as well as WorkManager producers. Exact type-to-grant mapping is the safety property: a broad “tamper during setup” suppression would hide a real attack. Permanent audit-only held rows avoid surprising parents with stale alerts after the window and preserve security evidence for retention/erasure processes.

## Alternatives considered

- **Android decides and drops setup alerts locally:** rejected because a modified client or manipulated clock could silence real tamper events, and direct producers would bypass the rule.
- **Hold every tamper event for 30 minutes:** rejected as an unsafe blanket bypass.
- **Release held rows at expiry:** rejected because old setup noise would arrive after the parent had moved on; new post-expiry events already restore normal protection reporting.
- **Complete from pair-claim or a stored report on poll:** rejected because pair-claim capabilities are unauthenticated and a stored all-ready report could be stale. Poll/job paths evaluate only timeout, never completion.
- **Use `lastSeen` or claim creation as the window anchor:** rejected because `lastSeen` moves and a pending claim has not authenticated as a device. `pairedAt` is stable and server-issued.
- **A separate scheduler with no external-cron path:** rejected. The shared evaluator runs in the existing device-silence runner and lazily on command poll.

## Consequences and costs

- This adds an R3 migration and a held-alert field that every parent-facing alert read must respect. Security reviewers must check export and acknowledgement as well as list/push behavior.
- Completion alert latency is bounded by the next authenticated capability upload, not the instant the Android setting changes. Android already uploads on the status screen and on changed reports.
- Ordinary uninstall/reinstall cannot always be distinguished from a fresh install after local credentials disappear. The guaranteed named path is the existing `dataCleared` signal; no broader reinstall claim is made.
- “N steps left” includes recommended grants while setup is incomplete, matching the existing `missing` projection; required-grant completion can therefore finish while recommended repairs remain visible afterward.
- Exactly-once push after a process crash has the same limits as the existing alert pipeline. Database dedupe prevents duplicate rows and repeated delivery on retries.

## Evidence

- `device-setup-policy.test.ts` covers required grants, exact hold/never-hold matrices, unknown state, the 30-minute boundary and setup-episode dedupe keys.
- Route/job tests cover held persistence without realtime/push, parent invisibility, authenticated completion, poll/job timeout sharing, protected-alert rollback and failed-rollback recovery on the next all-ready report, migration backfill with no alert on the next all-ready report, and the visible data-cleared path. Parent tests cover the server timestamp, Android-only first-setup counts, iOS/legacy repair copy, generic incomplete copy when no reliable step count exists, localized alert copy, grant labels, malformed params and EN/AR layouts. Live probe rows G30–G32 and full-suite outputs are recorded on the PR; physical-phone evidence is not claimed by the software suite.
