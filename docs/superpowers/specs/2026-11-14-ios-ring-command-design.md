# OSRA Kids iPhone ring command — approved design

- **Issue:** #750 (beta-A blocker, R3)
- **Date:** 2026-11-14
- **Status:** design approved by Claude on #750, with the server-owned `bodyKey` correction
- **Related:** Android `RingPolicy`, ADR-0012 (command queue), #718 (`bodyKey`/`bodyParams`), #756 (Android parity)

## Purpose and acceptance

A parent can ring an iPhone through the existing `ring` command. The alert uses AlarmKit on iOS 26+ so it sounds in Silent mode, Focus/Do Not Disturb and at volume zero. It stops only when:

1. the parent enters the OSRA Kids PIN;
2. the parent sends `stop_ring`; or
3. five minutes elapse.

Dismissing the system alert, swiping it away, pressing the side button, force-quitting, rebooting or going offline is not a stop. The controller re-arms a dismissed alert and reports each dismissal once. The PIN remains reachable in the app and through a notification. A stopped ring never re-arms.

Required evidence is the Mac test bed's KR01 and §1 escape rows, not merely compilation. The parent sees ringing, PIN stop, parent stop, child dismissal and timeout in English and Arabic. The UI/UX and Arabic Bureaus approve the ring UI and all new text before verification. Ahmed gives the R3 verdict and Fable the second key.

## Constraints and non-goals

- Use the existing `ring` and `stop_ring` command types and existing consent/family isolation.
- No server field, account, certificate, key or secret is added.
- No Critical Alerts entitlement is requested by this change. That fallback remains named and waits for Karim.
- No countdown widget is required: this is an alert-only AlarmKit configuration.
- No changes to Android ring behaviour or to the parent approve/deny access-request flow.
- No durable PIN value or hash enters ring state. Existing `ParentPinStore` performs verification and lockout.
- No macOS agent behaviour is added in this PR.

## Alternatives

1. **AlarmKit behind a protocol (chosen).** Production uses `AlarmManager.shared`; tests use a fake backend. This isolates pure state transitions and does not pretend simulator tests prove real alarm behaviour.
2. **Critical Alerts fallback.** Kept for a later, maintainer-authorised entitlement request, not implemented speculatively here.
3. **A custom notification loop.** Rejected: it is not alarm-grade and would repeat Android's dismiss/force-quit lessons.

## Components

### Pure policy and persisted state

Add `RingPolicy.swift` and `RingState.swift` to the shared package.

`RingPolicy` mirrors Android's stop sources and 300-second cap:

- `pinVerified` → `pin_stopped`;
- `parentCommand` → `parent_stopped`;
- `timeout` → `timed_out`.

`childDismissed` is an event, never a stop. Starting a new ring replaces the previous one and allocates a new end time. Stop and dismissal are idempotent within their respective dedupe keys.

`RingState` is Codable and stored in the app group, never in the Keychain:

- command UUID;
- start and end dates;
- stop source, if stopped;
- per-ring dismissal count.

An active ring resumes on launch. An expired ring stops as `timed_out`. A stopped ring does not resume.

### Alarm backend

`RingBackend` is a small protocol with operations to request/check authorization, schedule an alert, stop it by UUID and observe the set of scheduled UUIDs.

The production adapter uses `AlarmManager.shared`:

- authorization comes from `authorizationState`/`requestAuthorization`;
- the configuration is alert-only, with a fixed immediate schedule, default alarm sound and no countdown;
- the alert's stop/dismiss button is expected to dismiss, not to provide an OSRA stop;
- `alarmUpdates` supplies the current UUID set.

The backend never decides whether a dismissal is a real stop. That decision belongs to the policy/controller.

### Controller

`RingController` is `@MainActor` and orchestrates backend, app-group state, notification and `AlertReporter`.

On `start(commandId:)` it:

1. validates the UUID;
2. requests AlarmKit authorization;
3. schedules the immediate alert;
4. persists start/end state and presents the ring UI.

Authorization denial or a scheduling error produces no active state and a failed command ack with a typed reason.

On `alarmUpdates` it compares the active UUID. If that UUID disappears before the cap, it schedules it again and emits one warning per dismissal. If it is absent because an approved stop occurred, nothing re-arms. If it is absent because the cap elapsed, the controller times out and reports that state.

A local notification leads back to the ring UI when permission allows. Notification absence never suppresses the alarm itself.

### Commands and UI

`CommandAction` adds `ring` and `stopRing`. `CommandDrainer` receives a `RingCommandHandling` protocol in the same style as `LocateNowHandling`.

- `ring`: ack `applied` only after the alert is scheduled; otherwise `failed` with a typed reason.
- `stop_ring`: stop with `parentCommand` and ack idempotently, including when no ring is active.
- `RingView`: full-screen, L10n-only text, the existing `PinGateView` always reachable, and no child stop control. Opening the app while ringing returns to this view.

PIN success calls `stop(.pinVerified)`. Existing validation and five-try lockout are reused unchanged.

## Parent-visible event contract

Add `ring` to `AlertCategoryExtended` and the API's internal alert enum.

Each alert carries:

- `category: "ring"`;
- `metadata.state`: `child_dismissed`, `pin_stopped`, `parent_stopped` or `timed_out`;
- `metadata.ringId`: the originating command id;
- `dedupeKey`: `ring:<ringId>:<state>` for stops, and `ring:<ringId>:child_dismissed:<count>` for each dismissal.

There is no `ringing` alert: the command's applied ack already conveys it.

The server-owned localization mapping is fixed, never selected by the device:

| State | Server `bodyKey` | Required `bodyParams` |
|---|---|---|
| `child_dismissed` | `alertBodyRingChildDismissed` | `ringId`, `dismissalCount` |
| `pin_stopped` | `alertBodyRingPinStopped` | `ringId` |
| `parent_stopped` | `alertBodyRingParentStopped` | `ringId` |
| `timed_out` | `alertBodyRingTimedOut` | `ringId` |

Severities and push:

| State | Severity | Parent push |
|---|---|---|
| `child_dismissed` | `warning` | Yes; the alert re-arms |
| `pin_stopped` | `info` | Yes |
| `parent_stopped` | `info` | **Recorded without a push**, because the parent issued the stop |
| `timed_out` | `info` | Yes |

Server `shouldPush` suppresses only `parent_stopped`, leaving all existing policies unchanged.

The device sends only the category, state, ring id and dedupe key. It never sends `metadata.bodyKey` or `metadata.bodyParams`. The server maps `(ring, state)` to its own `bodyKey` and required params, using the #718 validation path. An API test must prove a device-supplied key is stripped and the server key is stored instead. Both HTTP 200 and 201 mean delivered.

The parent app renders each state through the #718 `bodyKey` mechanism and localized text, not raw metadata. English fallback text remains for older parent apps. No raw `state: value` rows are shown.

## Data flow

1. `ring` arrives through the authenticated command queue.
2. The controller schedules AlarmKit and persists the command UUID/end time.
3. The command is acked applied, and the ring UI is shown.
4. A system dismissal removes the UUID from `alarmUpdates`; the controller re-arms and reports one warning with a unique per-ring dismissal key.
5. A real stop calls the backend stop, persists its source and reports the matching state through the existing HMAC alert route.
6. A parent-side renderer displays the state from `metadata.bodyKey`/`bodyParams`, localized by the parent app.

## Error handling and offline behaviour

- Authorization denial and scheduling failure leave no active ring and ack `failed` with a typed reason.
- A scheduling retry never creates a second ring state or duplicate alert.
- A 200 or 201 alert response marks the corresponding event delivered. Other statuses leave it pending for a later drain/restart.
- Dismissal count is per ring, so two dismissals produce two distinct events and two distinct dedupe keys.
- A child cannot clear `shield.requestTimes` or any other request-throttle state.
- Existing encoding and stored entries remain valid; no migration or key-format change is introduced.

## Test plan

### Pure Swift tests

- Stop sources and the exact 300-second cap.
- UUID validation and start replacement.
- Authorization denial and schedule failure.
- Persistence across restart, timeout, and no re-arm after a real stop.
- Re-arm on a missing UUID before the cap, with one event per dismissal and increasing counters.
- 200 and 201 both delivered; non-delivered responses retry without a duplicate.
- `stop_ring` idempotency.
- Parent PIN success and existing lockout behaviour.

### API tests

- `ring` is accepted with each state and `ringId`.
- Dedupe returns 200 with the existing alert, not another alert or push.
- `parent_stopped` alone is not pushed; the other states retain existing policy.
- A caller-supplied `metadata.bodyKey` is stripped and replaced by the server's validated key.
- English fallback remains present.

### Parent tests

- Every state renders through its `bodyKey` and localized text, never raw metadata.
- English and Bureau-approved Arabic, light and dark, with direction-isolated identifiers/times.
- Existing suites remain green.

### Real iPhone rows (Mac test bed only)

- AlarmKit authorization and immediate alert.
- Silent switch, Focus/DND and volume zero.
- Child dismissal and repeated re-arm, with one parent event per dismissal.
- Home/swipe-up, app switcher, Notification Centre, Control Centre, side button, force-quit and offline are not stops.
- PIN stop, parent `stop_ring` and the five-minute cap.
- Reboot/resume, with no active ring after an approved stop.
- English/Arabic, light/dark screenshots and Arabic Bureau sign-off.

## Files and boundaries

Expected additions/changes are confined to:

- `apps/child-ios/Sources/FamilyShieldAgent/Ring*.swift`
- `apps/child-ios/App/OSRAAgentApp.swift` and `App/Info.plist`
- `apps/child-ios/Sources/FamilyShieldAgent/DeviceCommands.swift`, `RuleSync.swift` only where ring state needs clearing on consent withdrawal/unpair
- `apps/child-ios/Sources/FamilyShieldAgent/Resources/*.lproj` and package tests
- `packages/shared-types/src/{index.ts,world-class.ts}`
- `services/api/src/{lib/alerts.ts,lib/push/notify.ts,routes/alerts.ts}` and tests
- `apps/parent-app` alert rendering, L10n and tests
- `CHANGELOG.d`, `docs/TESTING.md`, roadmap row 5.5, and the implementation plan

No existing iOS enforcement is renamed or moved. Shared Swift additions remain additive, with portable tests included in the macOS test-count guard.

## Completion and handoff

Implement in small TDD steps: policy/state, backend/controller, commands/UI, API/push, parent rendering, documentation and device evidence. Each behavior lands with a test that fails without it. After CI and both Bureaus, hand to Claude for cross-family verification, Ahmed for the R3 verdict and Fable for the second key. Do not merge manually.
