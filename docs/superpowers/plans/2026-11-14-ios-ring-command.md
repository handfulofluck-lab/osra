# OSRA Kids iPhone ring command implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an AlarmKit iPhone ring that only the parent PIN, `stop_ring` or the five-minute cap can stop, with re-arm on dismissal and localized parent-visible events.

**Architecture:** A pure policy/state machine sits behind a small `RingBackend` protocol. A `RingController` orchestrates that backend, app-group state, command handling, notifications and alert reporting. AlarmKit and the real iPhone are verification targets, never test doubles; the Mac test bed supplies the physical evidence.

**Tech Stack:** Swift 5.9, SwiftPM/XCTest, AlarmKit iOS 26+, SwiftUI, TypeScript/Vitest, Prisma, Flutter/Riverpod/Dart.

**Spec:** `docs/superpowers/specs/2026-11-14-ios-ring-command-design.md`

## Global Constraints

- Stop only for `pinVerified`, `parentCommand` or `timeout`; the cap is exactly 300 seconds. Child dismissal, Home, side button, force-quit, reboot and offline are not stops.
- AlarmKit is alert-only, immediate, default sound, no countdown widget. Critical Alerts is not requested in this PR; Karim owns that fallback decision.
- No ring on iOS below 26: ack `failed` with `unsupported_os` and show the localized update line.
- While alive, measure timeout monotonically. Across reboot use the stored wall-clock end date; a +10 min wall jump inside a 30 s monotonic ring must not stop it. Timeout requires both clocks when available.
- `alarmUpdates` re-arms an active missing UUID and records each dismissal once. First dismissal pushes immediately; later pushes within 60 s coalesce. Three dismissals in 10 s produce three alerts and one push.
- `ring` and `stop_ring` reuse the authenticated command queue. `ring` acks applied only after scheduling; `stop_ring` is idempotent.
- Unpair or consent withdrawal stops locally and emits no ring alert.
- No `ringing` alert. Alert metadata carries only `state`, `ringId`, and dedupe key. States are `child_dismissed` (warning), `pin_stopped` (info), `parent_stopped` (info, no push), `timed_out` (info).
- Dedupe keys are `ring:<ringId>:<state>` and `ring:<ringId>:child_dismissed:<count>`. HTTP 200 and 201 both mean delivered.
- Devices never send `metadata.bodyKey`/`bodyParams`; the server maps `(ring, state)` and strips caller keys. Generic push remains a wake via `PUSH_ALERT_TITLE`/`PUSH_ALERT_BODY`, with no state, id or count in the payload.
- No Arabic is written by the implementer. English and Arabic go through UI/UX and Arabic Bureaus before verification. No secrets, settings changes, merges or deployments.

## Review Focus

- **Clock manipulation:** `testWallJumpDoesNotEndRingEarly` must fail if timeout reads only wall time.
- **Dismissal flooding:** `testThreeDismissalsInTenSecondsCreateThreeAlertsAndOnePush` must prove distinct events with one provider send.
- **No family left to notify:** `testUnpairAndConsentWithdrawalStopWithoutAlert` must fail if a ring alert is emitted.
- **Older iPhone:** `testRingBelowIOS26ReturnsUnsupportedOS` must fail if it schedules anything.
- **Lost response/restart:** `testDeliveredEventIsNotRetriedAfterRestart` must prove 200 and 201 both count as delivered, without a duplicate alert.

---

### Task 1: Pure ring policy and persisted state

**Files:**
- Create: `apps/child-ios/Sources/FamilyShieldAgent/RingPolicy.swift`
- Create: `apps/child-ios/Sources/FamilyShieldAgent/RingState.swift`
- Create: `apps/child-ios/Tests/FamilyShieldAgentTests/RingPolicyTests.swift`

**Interfaces:**
- Consumes: Foundation `UUID`, `Date`, `TimeInterval`.
- Produces: `RingStopSource`, `RingEventState`, `RingState`, `RingPolicy.duration`, `RingPolicy.hasTimedOut(state:nowWall:nowMonotonic:restarted:)`, `RingPolicy.dedupeKey(for:ringId:dismissalCount:)`.

- [ ] **Step 1: Write failing policy tests**

```swift
func testOnlyPINParentAndTimeoutAreStops() {
    XCTAssertEqual(RingPolicy.event(for: .pinVerified), .pinStopped)
    XCTAssertEqual(RingPolicy.event(for: .parentCommand), .parentStopped)
    XCTAssertEqual(RingPolicy.event(for: .timeout), .timedOut)
    XCTAssertNil(RingPolicy.event(for: .childDismissed))
}

func testWallJumpDoesNotEndRingEarly() {
    let state = RingState.fixture(endAt: Date(timeIntervalSince1970: 300), monotonicStart: 0)
    XCTAssertFalse(RingPolicy.hasTimedOut(state,
        nowWall: Date(timeIntervalSince1970: 600), nowMonotonic: 30, restarted: false))
}

func testTimeoutRequiresBothClocks() {
    XCTAssertTrue(RingPolicy.hasTimedOut(state,
        nowWall: Date(timeIntervalSince1970: 300), nowMonotonic: 300, restarted: false))
}
```

- [ ] **Step 2: Run the tests and verify they fail**

Run: `cd apps/child-ios && swift test --filter RingPolicyTests`
Expected: FAIL because these types do not exist.

- [ ] **Step 3: Implement the pure types**

`RingStopSource` is `String, Codable`: `pinVerified`, `parentCommand`, `timeout`. `RingEventState` is `String, Codable`: `childDismissed = "child_dismissed"`, `pinStopped = "pin_stopped"`, `parentStopped = "parent_stopped"`, `timedOut = "timed_out"`.

`RingState` is `Codable, Equatable` with `commandId: UUID`, `startedAt: Date`, `endAt: Date`, `monotonicStart: TimeInterval`, `stopSource: RingStopSource?`, `dismissalCount: Int`.

`RingPolicy.duration = 300`. `hasTimedOut` requires `nowWall >= endAt` and, when `restarted == false`, `nowMonotonic - monotonicStart >= duration`. When restarted, only the stored wall-clock end is consulted. Dedupe keys are `ring:<ringId>:<state>` and `ring:<ringId>:child_dismissed:<count>`.

- [ ] **Step 4: Run the tests and verify they pass**

Run: `cd apps/child-ios && swift test --filter RingPolicyTests`
Expected: PASS, including stop sources, cap, clock jump and dedupe key shape.

- [ ] **Step 5: Commit**

```bash
git add apps/child-ios/Sources/FamilyShieldAgent/RingPolicy.swift apps/child-ios/Sources/FamilyShieldAgent/RingState.swift apps/child-ios/Tests/FamilyShieldAgentTests/RingPolicyTests.swift
git commit -m "feat(ios): add the pure ring policy and persisted state (#750)"
```

---

### Task 2: AlarmKit backend and basic controller lifecycle

**Files:**
- Create: `apps/child-ios/Sources/FamilyShieldAgent/RingBackend.swift`
- Create: `apps/child-ios/Sources/FamilyShieldAgent/AlarmKitRingBackend.swift`
- Create: `apps/child-ios/Sources/FamilyShieldAgent/RingController.swift`
- Create: `apps/child-ios/Tests/FamilyShieldAgentTests/RingControllerTests.swift`

**Interfaces:**
- Consumes: Task 1's `RingState`, `RingPolicy`.
- Produces: `RingBackend` (`requestAuthorization`, `schedule`, `stop`, `scheduledIDs`, `updates`), `RingController.start`, `stop`, `resume`, `process(scheduledIDs:)`, `RingCommandError`.

- [ ] **Step 1: Write failing controller tests with a fake backend**

```swift
func testRingBelowIOS26ReturnsUnsupportedOS() async {
    let backend = FakeRingBackend(available: false)
    let controller = RingController(backend: backend, store: InMemoryRingStore())
    let error = await controller.start(UUID())
    XCTAssertEqual(error, .unsupportedOS)
    XCTAssertEqual(backend.scheduled.count, 0)
}

func testStartSchedulesAndPersists() async {
    let backend = FakeRingBackend(available: true, authorized: true)
    let controller = RingController(backend: backend, store: InMemoryRingStore())
    let id = UUID()
    XCTAssertNil(await controller.start(id))
    XCTAssertEqual(backend.scheduled, [id])
    XCTAssertEqual(controller.state?.commandId, id)
    XCTAssertEqual(controller.state?.dismissalCount, 0)
}

func testStopIsIdempotent() async {
    await controller.stop(.parentCommand)
    await controller.stop(.parentCommand)
    XCTAssertEqual(backend.stopCalls.count, 1)
}
```

- [ ] **Step 2: Run the tests and verify they fail**

Run: `cd apps/child-ios && swift test --filter RingControllerTests`
Expected: FAIL because the backend/controller do not exist.

- [ ] **Step 3: Implement backend and lifecycle**

Define `RingBackend` with:

```swift
func requestAuthorization() async -> Bool
func schedule(_ id: UUID) async throws
func stop(_ id: UUID) async throws
func scheduledIDs() async -> Set<UUID>
func updates() async -> AsyncStream<Set<UUID>>
```

`AlarmKitRingBackend` wraps `AlarmManager.shared` behind `if #available(iOS 26.0, *)`, using an alert-only `AlarmManager.AlarmConfiguration` with fixed immediate schedule, default sound and no countdown. `AlarmKitRingBackend.unsupported` is returned on older iOS.

`RingController.start` validates UUID, availability and authorization, then schedules before persisting `RingState`. `stop` is idempotent and stops only the current command. `resume` re-presents active state, and `process(scheduledIDs:)` re-arms a missing active UUID before the cap. No command acknowledgement is implemented in this task.

- [ ] **Step 4: Run the tests and verify they pass**

Run: `cd apps/child-ios && swift test --filter RingControllerTests`
Expected: PASS for unsupported OS, persistence, idempotent stop and re-arm.

- [ ] **Step 5: Commit**

```bash
git add apps/child-ios/Sources/FamilyShieldAgent/RingBackend.swift apps/child-ios/Sources/FamilyShieldAgent/AlarmKitRingBackend.swift apps/child-ios/Sources/FamilyShieldAgent/RingController.swift apps/child-ios/Tests/FamilyShieldAgentTests/RingControllerTests.swift
git commit -m "feat(ios): add the AlarmKit backend and ring lifecycle (#750)"
```

---

### Task 3: Dismissal reporting, timeout and offline idempotency

**Files:**
- Modify: `apps/child-ios/Sources/FamilyShieldAgent/RingController.swift`
- Create: `apps/child-ios/Sources/FamilyShieldAgent/RingAlertReporter.swift`
- Modify: `apps/child-ios/Tests/FamilyShieldAgentTests/RingControllerTests.swift`

**Interfaces:**
- Consumes: Task 1's states/dedupe keys, Task 2's backend/controller, existing `AlertReporter.send`.
- Produces: `RingAlertReporter.report(state:ringId:dismissalCount:) async -> Bool`, controller unpair/consent stop.

- [ ] **Step 1: Add failing dismissal, clock and offline tests**

```swift
func testDismissalRearmsAndIncrementsCount() async {
    await controller.start(id)
    await controller.process(scheduledIDs: [])
    await controller.process(scheduledIDs: [])
    XCTAssertEqual(backend.scheduled, [id, id, id])
    XCTAssertEqual(controller.state?.dismissalCount, 2)
}

func testDeliveredEventIsNotRetriedAfterRestart() async {
    await controller.start(id)
    await controller.process(scheduledIDs: [])
    let first = await reporter.nextStatus()
    XCTAssertTrue([200, 201].contains(first))
    await controller.resume()
    XCTAssertEqual(reporter.callCount, 1)
}

func testUnpairAndConsentWithdrawalStopWithoutAlert() async {
    await controller.start(id)
    await controller.stopForUnpair()
    XCTAssertNil(controller.state)
    XCTAssertEqual(reporter.callCount, 0)
}

func testChildDismissalDoesNotClearRequestTimes() async {
    let defaults = UserDefaults(suiteName: AgentIdentityStore.suiteName)
    defaults?.set(["app:old": 100.0], forKey: ShieldTapPolicy.requestTimesKey)
    await controller.start(id)
    await controller.process(scheduledIDs: [])
    XCTAssertNotNil(defaults?.dictionary(forKey: ShieldTapPolicy.requestTimesKey))
}
```

- [ ] **Step 2: Run the tests and verify they fail**

Run: `cd apps/child-ios && swift test --filter RingControllerTests`
Expected: FAIL for missing dismissal reporting and unpair handling.

- [ ] **Step 3: Implement reporting and offline-safe stop**

`RingAlertReporter` calls `AlertReporter.send` with `category: "ring"`, `metadata.state`, `metadata.ringId`, and the Task 1 dedupe key. `child_dismissed` is warning; other states are info. No `metadata.bodyKey`/`bodyParams` is sent. Both 200 and 201 are delivered; all other statuses leave the event pending. The English fallback is exactly:
- child dismissal: "The ring alert was dismissed on the phone and has been re-armed."
- PIN stop: "The parent PIN stopped the ring."
- parent stop: "The parent stopped the ring."
- timeout: "The ring stopped after 5 minutes."

Each dismissal increments `dismissalCount`, produces a new dedupe key and re-arms. Timeout stops with `timedOut` and uses Task 1's two-clock rule. Unpair/consent withdrawal clears state locally without calling the reporter. Dismissal never clears `shield.requestTimes` or any other request-throttle state.

- [ ] **Step 4: Run the tests and verify they pass**

Run: `cd apps/child-ios && swift test --filter RingControllerTests`
Expected: PASS for per-dismissal count, re-arm, delivered retry and no-family alert suppression.

- [ ] **Step 5: Commit**

```bash
git add apps/child-ios/Sources/FamilyShieldAgent/RingController.swift apps/child-ios/Sources/FamilyShieldAgent/RingAlertReporter.swift apps/child-ios/Tests/FamilyShieldAgentTests/RingControllerTests.swift
git commit -m "feat(ios): re-arm dismissals and make ring reporting idempotent (#750)"
```

---

### Task 4: Command handling, ring UI and notification

**Files:**
- Modify: `apps/child-ios/Sources/FamilyShieldAgent/DeviceCommands.swift`
- Create: `apps/child-ios/Sources/FamilyShieldAgent/RingView.swift`
- Create: `apps/child-ios/Sources/FamilyShieldAgent/RingNotifier.swift`
- Modify: `apps/child-ios/App/OSRAAgentApp.swift`
- Modify: `apps/child-ios/App/Info.plist`
- Create: `apps/child-ios/Tests/FamilyShieldAgentTests/RingCommandTests.swift`

**Interfaces:**
- Consumes: Tasks 2–3 controller and existing `PinGateView`, `AgentRootView`, `CommandDrainer`.
- Produces: `RingCommandHandling.startRing(id:)`, `stopRing()`, `CommandAction.ring`, `CommandAction.stopRing`.

- [ ] **Step 1: Add failing command and UI-state tests**

```swift
func testRingAcksOnlyAfterSchedule() async {
    let result = await CommandDrainer.drainNow(client: makeClient([DeviceCommand(id: "ring-1", type: "ring")]), ring: handler)
    XCTAssertEqual(result.handled, ["ring"])
    XCTAssertEqual(handler.startedIds, ["ring-1"])
}

func testUnsupportedOSIsFailed() async {
    handler.error = .unsupportedOS
    let result = await CommandDrainer.drainNow(client: makeClient([DeviceCommand(id: "ring-1", type: "ring")]), ring: handler)
    XCTAssertEqual(result.refused, ["ring"])
    XCTAssertEqual(handler.reason, "unsupported_os")
}

func testStopRingIsIdempotent() async {
    let result = await CommandDrainer.drainNow(client: makeClient([DeviceCommand(id: "stop-1", type: "stop_ring")]), ring: handler)
    XCTAssertEqual(result.handled, ["stop_ring"])
}

func testHomeOrBackgroundDoesNotStop() async {
    await controller.start(id)
    await controller.enterBackground()
    XCTAssertNotNil(controller.state)
    XCTAssertEqual(backend.stopCalls.count, 0)
}
```

- [ ] **Step 2: Run the tests and verify they fail**

Run: `cd apps/child-ios && swift test --filter RingCommandTests`
Expected: FAIL because command cases do not exist.

- [ ] **Step 3: Implement command and presentation integration**

Add `CommandAction.ring` and `stopRing` mappings and `RingCommandHandling`. `CommandDrainer` accepts the handler with the same default-injection style as the locator. `ring` acks applied only after scheduling; `stop_ring` acks idempotently.

`RingView` is full-screen and uses only `L10n.tr`: title, persistent-ring explanation and parent-PIN action. It embeds the existing `PinGateView`, so a child always has a route to a real stop. `AgentRootView` presents it while controller state is active and hides it after a real stop.

`RingNotifier` wraps `UNUserNotificationCenter` for the return-to-ring notification and cancellation. No visible string is literal. `App/Info.plist` gains `NSAlarmKitUsageDescription` with the exact English line: "OSRA alerts you when your parent rings this phone, even in Silent mode, Focus, and at volume zero." Arabic comes only from the Bureau.

- [ ] **Step 4: Run the tests and verify they pass**

Run: `cd apps/child-ios && swift test --filter RingCommandTests`
Expected: PASS for applied/failed ack reasons and stop idempotency. UI strings are exercised through the L10n key tests in Task 7.

- [ ] **Step 5: Commit**

```bash
git add apps/child-ios/Sources/FamilyShieldAgent/DeviceCommands.swift apps/child-ios/Sources/FamilyShieldAgent/RingView.swift apps/child-ios/Sources/FamilyShieldAgent/RingNotifier.swift apps/child-ios/App/OSRAAgentApp.swift apps/child-ios/App/Info.plist apps/child-ios/Tests/FamilyShieldAgentTests/RingCommandTests.swift
git commit -m "feat(ios): expose ring commands and the PIN-reachable ring UI (#750)"
```

---

### Task 5: API category, body keys, dedupe and push coalescing

**Files:**
- Modify: `packages/shared-types/src/index.ts`
- Modify: `packages/shared-types/src/world-class.ts`
- Modify: `services/api/src/lib/alerts.ts`
- Modify: `services/api/src/lib/push/notify.ts`
- Modify: `services/api/src/routes/alerts.ts`
- Modify: `services/api/test/alerts.test.ts`
- Modify: `services/api/test/alert-body-keys.test.ts`
- Modify: `services/api/test/push.test.ts`

**Interfaces:**
- Consumes: Task 3's four states, `ringId`, dismissal count and dedupe keys; #718's `bodyKey` validation.
- Produces: `AlertCategoryExtended.ring`, four ring body keys and `bodyParams`, push suppression for `parent_stopped`, 60-second dismissal coalescing.

- [ ] **Step 1: Add failing API and push tests**

```ts
it("accepts ring and returns the existing alert on dedupe", async () => {
  const first = await postRing({ state: "child_dismissed", ringId: "ring-1", dismissalCount: 1 });
  expect(first.status).toBe(201);
  const second = await postRing({ state: "child_dismissed", ringId: "ring-1", dismissalCount: 1 });
  expect(second.status).toBe(200);
});

it("strips a device bodyKey and stores the server key", async () => {
  const response = await postRing({ state: "pin_stopped", ringId: "ring-1",
    metadata: { bodyKey: "callerChoice", bodyParams: { ringId: "callerChoice" } });
  expect(response.alert.metadata.bodyKey).toBe("alertBodyRingPinStopped");
  expect(response.alert.metadata.bodyParams).toEqual({ ringId: "ring-1" });
});

it("suppresses only parent_stopped", () => {
  expect(shouldPush({ category: "ring", severity: "info", metadata: { state: "parent_stopped" } }, "info")).toBe(false);
  expect(shouldPush({ category: "ring", severity: "info", metadata: { state: "pin_stopped" } }, "info")).toBe(true);
  expect(shouldPush({ category: "ring", severity: "info", metadata: { state: "timed_out" } }, "info")).toBe(true);
  expect(shouldPush({ category: "ring", severity: "warning", metadata: { state: "child_dismissed" } }, "info")).toBe(true);
});

it("three dismissals in ten seconds create three alerts and one push", async () => {
  await postRing({ state: "child_dismissed", ringId: "ring-1", dismissalCount: 1 });
  await postRing({ state: "child_dismissed", ringId: "ring-1", dismissalCount: 2 });
  await postRing({ state: "child_dismissed", ringId: "ring-1", dismissalCount: 3 });
  expect(provider.sent).toHaveLength(1);
});
```

- [ ] **Step 2: Run the tests and verify they fail**

Run: `cd services/api && pnpm exec vitest run test/alerts.test.ts test/alert-body-keys.test.ts test/push.test.ts`
Expected: FAIL for missing category, mapping and coalescing.

- [ ] **Step 3: Implement the event schema and push rules**

Add `ring` to `AlertCategoryExtended` and `InternalAlertSchema`. Add `alertBodyRingChildDismissed`, `alertBodyRingPinStopped`, `alertBodyRingParentStopped`, `alertBodyRingTimedOut` to `ALERT_BODY_KEYS` and required params: `ringId` for all, plus `dismissalCount` for `child_dismissed`.

The route maps `(ring, state)` to the server key/params and passes them through #718 validation. Caller `metadata.bodyKey`/`bodyParams` is stripped before the validated pair is written. English fallback remains.

`shouldPush` suppresses only `parent_stopped`. Extend `AlertLike` with the metadata it needs. For `child_dismissed`, `notifyParentsOfAlert` checks for another dismissal alert from the same ring in the previous 60 seconds, excluding the current row. If found, it returns `skipped: "coalesced"` without sending; the parent fetches the latest count through the existing wake. Payload remains only the generic wake marker.

- [ ] **Step 4: Run the tests and verify they pass**

Run: `cd services/api && pnpm exec vitest run test/alerts.test.ts test/alert-body-keys.test.ts test/push.test.ts`
Expected: PASS for dedupe 200/201, server key replacement, suppression and three-dismissals-one-push.

- [ ] **Step 5: Commit**

```bash
git add packages/shared-types/src/index.ts packages/shared-types/src/world-class.ts services/api/src/lib/alerts.ts services/api/src/lib/push/notify.ts services/api/src/routes/alerts.ts services/api/test/alerts.test.ts services/api/test/alert-body-keys.test.ts services/api/test/push.test.ts
git commit -m "feat(api): add ring alerts and coalesce dismissal pushes (#750)"
```

---

### Task 6: Parent rendering and unsupported-OS line

**Files:**
- Modify: `apps/parent-app/lib/l10n/l10n.dart`
- Modify: `apps/parent-app/lib/features/alerts/alerts_screen.dart`
- Modify: `apps/parent-app/lib/l10n/app_en.arb`
- Modify: `apps/parent-app/lib/l10n/app_ar.arb` **only with Bureau-approved Arabic**
- Create: `apps/parent-app/test/ring_alert_test.dart`

**Interfaces:**
- Consumes: Task 5's ring `bodyKey`, `bodyParams`, English fallback and `unsupported_os`.
- Produces: localized ring detail in English/Arabic without raw metadata rows, plus the localized unsupported-OS line.

- [ ] **Step 1: Add failing renderer tests**

```dart
test('ring child dismissal uses bodyKey, not raw metadata', () {
  final alert = Alert(
    id: 'a1', childId: 'c1', severity: 'warning', category: 'ring',
    title: 'Ring', body: 'The ring alert was dismissed and re-armed.',
    metadata: {
      'bodyKey': 'alertBodyRingChildDismissed',
      'bodyParams': {'ringId': 'ring-1', 'dismissalCount': 2},
      'state': 'child_dismissed', 'ringId': 'ring-1',
    },
  );
  expect(alertBodyFor(alert, 'en'), contains('2'));
  expect(alertBodyFor(alert, 'en'), isNot(contains('state: child_dismissed')));
});

test('unsupported OS has a localized update reason', () {
  expect(alertBodyFor(alertWithReason('unsupported_os'), 'en'),
      contains('cannot ring'));
});
```

- [ ] **Step 2: Run the tests and verify they fail**

Run: `cd apps/parent-app && flutter test test/ring_alert_test.dart`
Expected: FAIL because the ring body helper does not exist.

- [ ] **Step 3: Implement localized ring rendering**

Add `alertBodyFor(alert, language)` with a `bodyKey` switch and the English fallback `alert.body`. Ring states use `bodyParams.ringId` and, for dismissal, `dismissalCount`. No raw `state: value` rows are printed. Add `unsupported_os` to the reason renderer with the line specified in the spec.

Add English keys in `app_en.arb`. Arabic keys enter only after the Arabic Bureau posts exact approved lines; copy those lines byte for byte and request `Bureau review: #<PR>` on #604. Include light/dark English/Arabic screenshots on #650 for UI/UX review.

- [ ] **Step 4: Run the tests and verify they pass**

Run: `cd apps/parent-app && flutter test test/ring_alert_test.dart`
Expected: PASS for localized state text and unsupported OS. Run `flutter analyze` too.

- [ ] **Step 5: Commit**

```bash
git add apps/parent-app/lib/l10n/l10n.dart apps/parent-app/lib/features/alerts/alerts_screen.dart apps/parent-app/lib/l10n/app_en.arb apps/parent-app/lib/l10n/app_ar.arb apps/parent-app/test/ring_alert_test.dart
git commit -m "feat(parent): localize ring alerts and unsupported iOS (#750)"
```

---

### Task 7: Package strings, count guard and verification documentation

**Files:**
- Modify: `apps/child-ios/Sources/FamilyShieldAgent/Resources/en.lproj/Localizable.strings`
- Modify: `apps/child-ios/Sources/FamilyShieldAgent/Resources/ar.lproj/Localizable.strings` **only with Bureau-approved Arabic**
- Modify: `apps/child-ios/Tests/FamilyShieldAgentTests/L10nTests.swift`
- Modify: `.github/workflows/ios-ci.yml`
- Create: `CHANGELOG.d/2026-11-14-ios-ring-command.md`
- Modify: `docs/TESTING.md`
- Modify: `docs/ROADMAP.md`

**Interfaces:**
- Consumes: Tasks 4 and 6's new L10n keys and all portable tests added above.
- Produces: localized ring resources, exact macOS/iOS discovery counts and the device-evidence procedure.

- [ ] **Step 1: Add failing localization/count tests**

Add assertions that every new ring key exists in both catalogs, has no empty value, and preserves existing key sets. Compute the actual discovery count with `swift test list`; do not guess it. Update the macOS guard by the number of new portable tests, not by the number of test methods that are iOS-only.

- [ ] **Step 2: Run the tests and verify they fail**

Run: `cd apps/child-ios && swift test --filter L10nTests`
Expected: FAIL for missing ring keys.

- [ ] **Step 3: Add approved strings and documentation**

Use the English ring strings and the Arabic Bureau's exact lines. `NSAlarmKitUsageDescription` follows the same review. Add the changelog fragment and the KR01/§1 device procedure to `docs/TESTING.md`. Move roadmap row 5.5 to in-progress with #750 and the remaining device work named, not to verified.

- [ ] **Step 4: Run all repository gates**

Run: `node scripts/check-docs-links.mjs`, `node scripts/check-workflows.mjs --strict`, `node scripts/check-ci-cost-guardrails.mjs`, `node scripts/check-ci-paths.mjs`, `node scripts/verified-gate-policy.mjs --selftest`, `cd apps/child-ios && swift test list`, and the platform suites from Tasks 1–6.
Expected: all pass; exact discovery counts are recorded for the PR body.

- [ ] **Step 5: Commit**

```bash
git add apps/child-ios/Sources/FamilyShieldAgent/Resources apps/child-ios/Tests/FamilyShieldAgentTests/L10nTests.swift .github/workflows/ios-ci.yml CHANGELOG.d/2026-11-14-ios-ring-command.md docs/TESTING.md docs/ROADMAP.md
git commit -m "feat(ios): localize ring and document its evidence (#750)"
```

---

### Task 8: Bureau and independent verification handoff

**Files:**
- No product-code changes. Evidence lives on #650, #604 and the implementation PR.

**Interfaces:**
- Consumes: Tasks 1–7's exact head and test results.
- Produces: UI/UX and Arabic decisions, cross-family verification, Ahmed's R3 verdict and Fable's second key, then auto-merge.

- [ ] **Step 1: Post Bureau evidence**

Post `UI/UX review: #<PR>` on #650 with light/dark English/Arabic screenshots and the ring flow. Post `Bureau review: #<PR>` on #604 with the changed keys and the exact head. Do not self-approve either Bureau.

- [ ] **Step 2: Run the full native and repository matrix**

Require green iOS, macOS, hosted Keychain and live-API jobs at the exact head, plus API, parent, workflow, cost, path, docs and secret scans. Paste raw counts and the fail-before tests each change would otherwise break.

- [ ] **Step 3: Request independent verification**

Set `risk:R3` and `state:ready-for-verification`, enable auto-merge, and ask Claude for cross-family verification, Ahmed for the R3 verdict and Fable for the second key. Mac test bed runs KR01 and §1; author claims no physical evidence personally.

- [ ] **Step 4: Merge only after all signatures and gates are green**

Wait for both Bureaus, `Verified-sha` at the exact head, Fable's key and `verified-gate`. Auto-merge is the only merge mechanism. Confirm head-branch deletion and report the after-merge state, without starting #677 early.
