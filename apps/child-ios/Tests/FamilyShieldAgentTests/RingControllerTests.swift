import Foundation
import XCTest
@testable import FamilyShieldAgent

final class InMemoryRingStore: RingStore {
    var stored: RingState?
    func load() -> RingState? { stored }
    func save(_ state: RingState?) { stored = state }
}

final class FakeRingBackend: RingBackend {
    let available: Bool
    var authorized: Bool
    var scheduled: [UUID] = []
    var stopCalls: [UUID] = []
    var authorizationCalls = 0
    var scheduleError: Error?
    var stopError: Error?
    var scheduledError: Error?
    var scheduleGate: (() async -> Void)?
    private var continuation: AsyncStream<Set<UUID>>.Continuation?

    init(available: Bool = true, authorized: Bool = true) {
        self.available = available
        self.authorized = authorized
    }

    func requestAuthorization() async -> Bool {
        authorizationCalls += 1
        return authorized
    }

    func schedule(_ id: UUID) async throws {
        if let scheduleError { throw scheduleError }
        if let scheduleGate { await scheduleGate() }
        scheduled.append(id)
    }

    func stop(_ id: UUID) async throws {
        if let stopError { throw stopError }
        stopCalls.append(id)
        scheduled.removeAll { $0 == id }
    }

    func scheduledIDs() async throws -> Set<UUID> {
        if let scheduledError { throw scheduledError }
        return Set(scheduled)
    }

    func updates() async -> AsyncStream<Set<UUID>> {
        AsyncStream { continuation = $0 }
    }

    func emit() { continuation?.yield(Set(scheduled)) }
}

@MainActor
final class RingControllerTests: XCTestCase {
    private let id = UUID(uuidString: "6F1C2B8E-3D4A-4E5F-9A0B-1C2D3E4F5A6B")!
    private var backend: FakeRingBackend!
    private var store: InMemoryRingStore!
    private var history: InMemoryRingHistory!
    private var reporter: RecordingRingReporter!
    private var wall = Date(timeIntervalSince1970: 1_000)
    private var uptime = 10.0
    private var bootSession: TimeInterval = 1

    override func setUp() {
        super.setUp()
        backend = FakeRingBackend()
        store = InMemoryRingStore()
        history = InMemoryRingHistory()
        reporter = RecordingRingReporter()
        bootSession = 1
        AgentIdentityStore.secrets = InMemorySecretStore()
        AgentIdentityStore.clear()
    }

    override func tearDown() {
        let defaults = UserDefaults(suiteName: AgentIdentityStore.suiteName)
        defaults?.removeObject(forKey: ShieldTapPolicy.requestTimesKey)
        defaults?.removeObject(forKey: RingAlertReporter.deliveredKey)
        defaults?.removeObject(forKey: RingAlertReporter.pendingKey)
        UserDefaultsRingStore().save(nil)
        UserDefaultsRingHistory.clear()
        ParentPinStore.clear()
        AgentIdentityStore.clear()
        super.tearDown()
    }

    private func controller(reporter: RingAlertReporting? = nil,
                            sleep: ((TimeInterval) async throws -> Void)? = nil) -> RingController {
        RingController(backend: backend, store: store, history: history, reporter: reporter ?? self.reporter,
                       now: { self.wall }, monotonic: { self.uptime },
                       bootSession: { self.bootSession }, sleep: sleep ?? { self.uptime += $0 })
    }

    private func flushTasks() async {
        for _ in 0..<8 { await Task.yield() }
    }

    func testRingBelowIOS26ReturnsUnsupportedOS() async {
        backend = FakeRingBackend(available: false)
        let controller = controller()
        let error = await controller.start(id)
        XCTAssertEqual(error, .unsupportedOS)
        XCTAssertEqual(backend.authorizationCalls, 0)
        XCTAssertTrue(backend.scheduled.isEmpty)
        XCTAssertNil(controller.state)
    }

    func testStartSchedulesAndPersists() async {
        let controller = controller()
        let error = await controller.start(id)
        XCTAssertNil(error)
        XCTAssertEqual(backend.scheduled, [id])
        XCTAssertEqual(controller.state?.commandId, id)
        XCTAssertEqual(controller.state?.dismissalCount, 0)
        XCTAssertEqual(store.load()?.endAt, wall.addingTimeInterval(300))
        XCTAssertEqual(store.load()?.monotonicStart, uptime)
    }

    func testInvalidCommandIdDoesNotSchedule() async {
        let controller = controller()
        let error = await controller.start(commandId: "not-a-uuid")
        XCTAssertEqual(error, .invalidCommand)
        XCTAssertTrue(backend.scheduled.isEmpty)
        XCTAssertNil(store.load())
    }

    func testAuthorizationDenialSchedulesNothing() async {
        backend.authorized = false
        let controller = controller()
        let error = await controller.start(id)
        XCTAssertEqual(error, .authorizationDenied)
        XCTAssertTrue(backend.scheduled.isEmpty)
        XCTAssertNil(store.load())
    }

    func testScheduleFailureLeavesNoActiveRing() async {
        struct Refused: Error {}
        backend.scheduleError = Refused()
        let controller = controller()
        let error = await controller.start(id)
        XCTAssertEqual(error, .scheduleFailed)
        XCTAssertNil(store.load())
        XCTAssertNil(controller.state)
    }

    func testStopIsIdempotentAndOnlyStopsCurrentCommand() async {
        let controller = controller()
        await controller.start(id)
        await controller.stop(.parentCommand, commandId: UUID())
        XCTAssertTrue(backend.stopCalls.isEmpty)
        await controller.stop(.parentCommand)
        await controller.stop(.parentCommand)
        XCTAssertEqual(backend.stopCalls, [id])
        XCTAssertEqual(reporter.calls.map(\.state), [.parentStopped])
        XCTAssertNil(store.load(), "a delivered parent stop clears its active state")
    }

    func testMissingAlarmIsRearmedBeforeTheCap() async {
        let controller = controller()
        await controller.start(id)
        await controller.process(scheduledIDs: [])
        XCTAssertEqual(backend.scheduled, [id, id])
        XCTAssertEqual(controller.state?.commandId, id)
    }

    func testResumeRestoresActiveStateWithoutCountingInitialSyncAsDismissal() async {
        await controller().start(id)
        let resumed = self.controller()
        await resumed.resume()
        XCTAssertEqual(resumed.state?.commandId, id)
        XCTAssertEqual(resumed.state?.dismissalCount, 0)
        XCTAssertEqual(backend.scheduled, [id])
    }

    func testStoppedRingDoesNotResume() async {
        let controller = controller()
        await controller.start(id)
        await controller.stop(.pinVerified)
        let resumed = self.controller()
        await resumed.resume()
        XCTAssertNil(resumed.state)
        XCTAssertEqual(backend.stopCalls, [id])
        XCTAssertEqual(backend.scheduled, [])
    }
}


@MainActor
final class RecordingRingReporter: RingAlertReporting {
    var statuses: [Int] = [201]
    var nextOutcome: RingReportOutcome?
    private(set) var calls: [(state: RingEventState, ringId: UUID, count: Int, afterRestart: Bool)] = []
    private var delivered = Set<String>()
    private var pending = [RingPendingEvent]()
    var callCount: Int { calls.count }

    func pendingEvents() -> [RingPendingEvent] { pending }

    func report(state: RingEventState, ringId: UUID, dismissalCount: Int,
                afterRestart: Bool) async -> RingReportOutcome {
        let key = RingPolicy.dedupeKey(for: state, ringId: ringId, dismissalCount: dismissalCount)
        guard !delivered.contains(key) else { return .delivered }
        let event = RingPendingEvent(state: state, ringId: ringId, dismissalCount: dismissalCount, afterRestart: afterRestart)
        if !pending.contains(event) { pending.append(event) }
        calls.append((state, ringId, dismissalCount, afterRestart))
        if let nextOutcome { return nextOutcome }
        let status = statuses.count > 1 ? statuses.removeFirst() : statuses[0]
        guard status == 200 || status == 201 else { return .pending }
        delivered.insert(key)
        pending.removeAll { $0 == event }
        return .delivered
    }
}

@MainActor
extension RingControllerTests {
    func testDismissalRearmsAndIncrementsCount() async {
        let controller = controller()
        await controller.start(id)
        await controller.process(scheduledIDs: [])
        await controller.process(scheduledIDs: [])
        XCTAssertEqual(backend.scheduled, [id, id, id])
        XCTAssertEqual(controller.state?.dismissalCount, 2)
        XCTAssertEqual(reporter.calls.map(\.count), [1, 2])
    }

    func testDeliveredEventIsNotRetriedAfterRestart() async {
        let controller = controller()
        await controller.start(id)
        await controller.process(scheduledIDs: [])
        XCTAssertEqual(reporter.callCount, 1)
        await controller.resume()
        XCTAssertEqual(reporter.callCount, 1)
    }

    func testOfflineEventRetriesWithoutADuplicateAfter200() async {
        reporter.statuses = [500, 200]
        let controller = controller()
        await controller.start(id)
        await controller.process(scheduledIDs: [])
        XCTAssertEqual(reporter.callCount, 1)
        await controller.resume()
        XCTAssertEqual(reporter.callCount, 2)
        await controller.resume()
        XCTAssertEqual(reporter.callCount, 2)
    }

    func testUnpairStopsWithoutAlert() async {
        let controller = controller()
        await controller.start(id)
        await controller.stopForUnpair()
        XCTAssertNil(controller.state)
        XCTAssertNil(store.load())
        XCTAssertEqual(backend.stopCalls, [id])
        XCTAssertEqual(reporter.callCount, 0)
    }

    func testConsentWithdrawalStopsWithoutAlert() async {
        let controller = controller()
        await controller.start(id)
        await controller.stopForConsentWithdrawal()
        XCTAssertNil(controller.state)
        XCTAssertEqual(reporter.callCount, 0)
    }

    func testWallJumpDoesNotTimeoutAndBothClocksStop() async {
        let controller = controller()
        await controller.start(id)
        wall = wall.addingTimeInterval(600)
        uptime += 30
        await controller.process(scheduledIDs: [])
        XCTAssertEqual(controller.state?.stopSource, nil)
        XCTAssertEqual(reporter.calls.map(\.state), [.childDismissed])
        uptime += 270
        await controller.process(scheduledIDs: [id])
        XCTAssertEqual(reporter.calls.map(\.state), [.childDismissed, .timedOut])
        XCTAssertNil(controller.state)
    }

    func testParentStopIsRecordedWithoutRearm() async {
        let controller = controller()
        await controller.start(id)
        await controller.stop(.parentCommand)
        XCTAssertEqual(reporter.calls.map(\.state), [.parentStopped])
        XCTAssertNil(controller.state)
        await controller.process(scheduledIDs: [])
        XCTAssertEqual(backend.scheduled, [])
    }

    func testOfflineStopIsRetriedWithoutASecondBackendStop() async {
        reporter.statuses = [500, 201]
        let controller = controller()
        await controller.start(id)
        await controller.stop(.pinVerified)
        XCTAssertEqual(store.load()?.stopSource, .pinVerified)
        XCTAssertEqual(backend.stopCalls, [id])
        await controller.resume()
        XCTAssertEqual(reporter.callCount, 2)
        XCTAssertEqual(backend.stopCalls, [id])
        XCTAssertNil(store.load())
    }

    func testChildDismissalDoesNotClearRequestTimes() async {
        let defaults = UserDefaults(suiteName: AgentIdentityStore.suiteName)
        defaults?.set(["app:old": 100.0], forKey: ShieldTapPolicy.requestTimesKey)
        let controller = controller()
        await controller.start(id)
        await controller.process(scheduledIDs: [])
        XCTAssertEqual(defaults?.dictionary(forKey: ShieldTapPolicy.requestTimesKey) as? [String: Double],
                       ["app:old": 100.0])
    }

    func testReporterUsesDedupeAndNeverSendsBodyKeys() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: AgentIdentityStore.suiteName))
        XCTAssertTrue(AgentIdentityStore.save(AgentIdentity(
            apiBaseURL: URL(string: "https://api.example.invalid")!, deviceToken: "device-jwt", deviceId: "dev-1",
            childId: "child-1", familyId: "fam-1", hmacSecret: "hmac")))
        var requests: [URLRequest] = []
        let reporter = RingAlertReporter(defaults: defaults, sender: { request in
            requests.append(request)
            return (201, Data())
        })
        let first = await reporter.report(state: .childDismissed, ringId: id, dismissalCount: 2)
        let second = await reporter.report(state: .childDismissed, ringId: id, dismissalCount: 2)
        XCTAssertEqual(first, .delivered)
        XCTAssertEqual(second, .delivered)
        XCTAssertEqual(requests.count, 1)
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(requests[0].httpBody)) as? [String: Any])
        XCTAssertEqual(body["category"] as? String, "ring")
        XCTAssertEqual(body["severity"] as? String, "warning")
        XCTAssertEqual(body["dedupeKey"] as? String, "ring:\(id.uuidString.lowercased()):child_dismissed:2")
        let metadata = try XCTUnwrap(body["metadata"] as? [String: Any])
        XCTAssertEqual(metadata["state"] as? String, "child_dismissed")
        XCTAssertEqual(metadata["ringId"] as? String, id.uuidString.lowercased())
        XCTAssertNil(metadata["bodyKey"])
        XCTAssertNil(metadata["bodyParams"])
    }

    func testReporterRetriesAnyStatusOtherThan200Or201() async {
        let defaults = UserDefaults(suiteName: AgentIdentityStore.suiteName)
        var statuses = [500, 200]
        var attempts: [Int] = []
        let reporter = RingAlertReporter(defaults: defaults,
                                            reporter: AlertReporter(apiBaseURL: URL(string: "https://api.example.invalid")!, hmacSecret: "hmac"),
                                            sender: { _ in
            let status = statuses.removeFirst()
            attempts.append(status)
            return (status, Data())
        })
        XCTAssertTrue(AgentIdentityStore.save(AgentIdentity(
            apiBaseURL: URL(string: "https://api.example.invalid")!, deviceToken: "device-jwt", deviceId: "dev-1",
            childId: "child-1", familyId: "fam-1", hmacSecret: "hmac")))
        let first = await reporter.report(state: .timedOut, ringId: id, dismissalCount: 0)
        let second = await reporter.report(state: .timedOut, ringId: id, dismissalCount: 0)
        XCTAssertEqual(first, .pending)
        XCTAssertEqual(second, .delivered, "delivery attempts: \(attempts)")
        XCTAssertEqual(attempts, [500, 200])
    }
}


final class InMemoryRingHistory: RingHistory {
    private var ids = Set<UUID>()
    func contains(_ id: UUID) -> Bool { ids.contains(id) }
    func record(_ id: UUID) { ids.insert(id) }
}

@MainActor
extension RingControllerTests {
    func testStoppedRingReplayIsAcknowledgedWithoutScheduling() async {
        let controller = controller()
        await controller.start(id)
        await controller.stop(.parentCommand)
        let replayError = await controller.start(id)
        XCTAssertNil(replayError)
        XCTAssertEqual(backend.scheduled, [], "the stopped alarm stays cancelled")
        XCTAssertEqual(backend.stopCalls, [id])
        XCTAssertEqual(reporter.callCount, 1)
    }

    func testPINLockoutDoesNotStopTheRing() async {
        let controller = controller()
        await controller.start(id)
        var lockout = PinLockout()
        for _ in 1...5 { lockout.recordFailure(now: wall) }
        XCTAssertTrue(lockout.isLocked(now: wall))
        XCTAssertNotNil(controller.state)
        XCTAssertNil(controller.state?.stopSource)
    }
}


@MainActor
extension RingControllerTests {
    func testEnglishFallbacksFollowTheBureau() async throws {
        let defaults = UserDefaults(suiteName: AgentIdentityStore.suiteName)
        XCTAssertTrue(AgentIdentityStore.save(AgentIdentity(
            apiBaseURL: URL(string: "https://api.example.invalid")!, deviceToken: "device-jwt", deviceId: "dev-1",
            childId: "child-1", familyId: "fam-1", hmacSecret: "hmac")))
        var bodies: [[String: Any]] = []
        let reporter = RingAlertReporter(
            defaults: defaults,
            reporter: AlertReporter(apiBaseURL: URL(string: "https://api.example.invalid")!, hmacSecret: "hmac"),
            sender: { request in
                bodies.append(try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as! [String: Any])
                return (201, Data())
            })
        let cases: [(RingEventState, Int, String)] = [
            (.childDismissed, 1, "The ring alert was dismissed on the phone. It is ringing again."),
            (.childDismissed, 2, "The ring alert was dismissed on the phone 2 times. It is still ringing."),
            (.pinStopped, 0, "The ring was stopped on the phone with the parent PIN."),
            (.parentStopped, 0, "A parent stopped the ring from the OSRA app."),
            (.timedOut, 0, "The ring ended by itself after 5 minutes."),
        ]
        for (state, count, expected) in cases {
            let delivered = await reporter.report(state: state, ringId: id, dismissalCount: count)
            XCTAssertEqual(delivered, .delivered)
            let body = try XCTUnwrap(bodies.last)
            XCTAssertEqual(body["title"] as? String, "Phone ring")
            XCTAssertEqual(body["body"] as? String, expected)
        }
    }
}


extension InMemoryRingHistory {
    func remove(_ id: UUID) { ids.remove(id) }
}

@MainActor
extension RingControllerTests {
    func testOnlineRestartWithMovedClockResumesRing() async {
        reporter.nextOutcome = .resume(after: 240)
        let controller = controller()
        await controller.start(id)
        wall = wall.addingTimeInterval(600)
        uptime = 0
        await controller.resume()
        XCTAssertEqual(controller.state?.stopSource, nil)
        XCTAssertEqual(controller.state?.endAt, wall.addingTimeInterval(240))
        XCTAssertEqual(controller.state?.monotonicStart, uptime)
        XCTAssertFalse(history.contains(id))
        XCTAssertEqual(backend.scheduled, [id], "the cancelled alarm is re-armed once")
        XCTAssertEqual(backend.stopCalls, [id])
        XCTAssertEqual(reporter.calls.map(\.afterRestart), [true])
    }

    func testOfflineRestartRecordsAfterRestart() async {
        let controller = controller()
        await controller.start(id)
        wall = wall.addingTimeInterval(600)
        uptime = 0
        await controller.resume()
        XCTAssertNil(controller.state)
        XCTAssertNil(store.load())
        XCTAssertEqual(reporter.calls.map(\.state), [.timedOut])
        XCTAssertEqual(reporter.calls.map(\.afterRestart), [true])
        XCTAssertEqual(backend.stopCalls, [id])
    }

    func testGenuineTimeoutAfterRestartRecordsAfterRestart() async {
        let controller = controller()
        await controller.start(id)
        wall = wall.addingTimeInterval(300)
        uptime = 0
        await controller.resume()
        XCTAssertNil(controller.state)
        XCTAssertEqual(reporter.calls.map(\.state), [.timedOut])
        XCTAssertEqual(reporter.calls.map(\.afterRestart), [true])
    }

    func testActiveRestartResponseResumesWithoutMarkingTimeoutDelivered() async throws {
        let defaults = UserDefaults(suiteName: AgentIdentityStore.suiteName)
        XCTAssertTrue(AgentIdentityStore.save(AgentIdentity(
            apiBaseURL: URL(string: "https://api.example.invalid")!, deviceToken: "device-jwt", deviceId: "dev-1",
            childId: "child-1", familyId: "fam-1", hmacSecret: "hmac")))
        var requestBody: [String: Any]?
        let reporter = RingAlertReporter(
            defaults: defaults,
            reporter: AlertReporter(apiBaseURL: URL(string: "https://api.example.invalid")!, hmacSecret: "hmac"),
            sender: { request in
                requestBody = try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any]
                return (200, Data(#"{"active":true,"retryAfterSeconds":240}"#.utf8))
            })
        let outcome = await reporter.report(state: .timedOut, ringId: id, dismissalCount: 0, afterRestart: true)
        XCTAssertEqual(outcome, .resume(after: 240))
        let body = try XCTUnwrap(requestBody)
        let metadata = try XCTUnwrap(body["metadata"] as? [String: Any])
        XCTAssertEqual(metadata["afterRestart"] as? Bool, true)
        XCTAssertEqual(body["body"] as? String, "The ring ended after the phone was restarted.")
        XCTAssertNil(defaults?.stringArray(forKey: RingAlertReporter.deliveredKey))
    }
}


@MainActor
extension RingControllerTests {
    func testLateStopForEarlierRingLeavesCurrentRing() async {
        let newer = UUID()
        let controller = controller()
        await controller.start(id)
        await controller.start(newer)
        await controller.stop(.parentCommand, commandId: id)
        XCTAssertEqual(controller.state?.commandId, newer)
        XCTAssertEqual(reporter.callCount, 0)
        await controller.stop(.parentCommand, commandId: newer)
        XCTAssertNil(controller.state)
        XCTAssertEqual(reporter.calls.map(\.state), [.parentStopped])
    }
}


@MainActor
extension RingControllerTests {
    struct TransportFailure: Error {}

    private func pairForTransport() {
        let base = PairingServerField.builtIn() ?? URL(string: "https://api.example.invalid")!
        XCTAssertTrue(AgentIdentityStore.save(AgentIdentity(
            apiBaseURL: base, deviceToken: "device-jwt", deviceId: "dev-1",
            childId: "child-1", familyId: "fam-1", hmacSecret: "hmac")))
    }

    private func transportReporter(_ defaults: UserDefaults, status: Int,
                                   requests: inout [URLRequest]) -> RingAlertReporter {
        RingAlertReporter(defaults: defaults,
                          reporter: AlertReporter(apiBaseURL: URL(string: "https://api.example.invalid")!, hmacSecret: "hmac"),
                          sender: { request in
            requests.append(request)
            return (status, Data())
        })
    }

    func testDeadlineStopsAt300WithoutProcessCall() async {
        let controller = controller()
        await controller.start(id)
        uptime = 10
        await flushTasks()
        XCTAssertEqual(backend.stopCalls, [id])
        XCTAssertEqual(reporter.calls.map(\.state), [.timedOut])
        XCTAssertNil(controller.state)
    }

    func testDeadlineDoesNotStopAt299Point9() async {
        let controller = controller(sleep: { self.uptime += min($0, 299.9) })
        await controller.start(id)
        uptime = 10
        await flushTasks()
        XCTAssertTrue(backend.stopCalls.isEmpty)
        uptime = 309.9
        await controller.resume()
        await flushTasks()
        XCTAssertEqual(backend.stopCalls, [id])
    }

    func testCancellationFailureIsFailedAndRetriedWithoutFalseDelivery() async {
        let controller = controller()
        await controller.start(id)
        backend.stopError = TransportFailure()
        let first = await controller.stop(.parentCommand)
        XCTAssertEqual(first, .stopFailed)
        XCTAssertEqual(reporter.callCount, 0)
        XCTAssertEqual(store.load()?.stopSource, .parentCommand)
        backend.stopError = nil
        let retry = await controller.stop(.parentCommand)
        XCTAssertNil(retry)
        XCTAssertEqual(backend.stopCalls, [id])
        XCTAssertEqual(reporter.calls.map(\.state), [.parentStopped])
        XCTAssertNil(controller.state)
    }

    func testReplacementCancellationFailureKeepsPreviousRing() async {
        let controller = controller()
        let newer = UUID()
        await controller.start(id)
        backend.stopError = TransportFailure()
        let error = await controller.start(newer)
        XCTAssertEqual(error, .scheduleFailed)
        XCTAssertEqual(controller.state?.commandId, id)
        XCTAssertEqual(backend.scheduled, [id])
        backend.stopError = nil
        let retry = await controller.start(newer)
        XCTAssertNil(retry)
        XCTAssertEqual(controller.state?.commandId, newer)
        XCTAssertEqual(backend.scheduled, [newer])
    }

    func testReporterCreatedBeforePairingUsesCurrentIdentity() async {
        let defaults = try! XCTUnwrap(UserDefaults(suiteName: AgentIdentityStore.suiteName))
        var requests: [URLRequest] = []
        let reporter = RingAlertReporter(defaults: defaults, sender: { request in
            requests.append(request)
            return (201, Data())
        })
        pairForTransport()
        let result = await reporter.report(state: .pinStopped, ringId: id, dismissalCount: 0)
        XCTAssertEqual(result, .delivered)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].url?.path, "/v1/alerts/internal")
    }

    func testPendingRestartAnswerKeepsAlarmScheduled() async {
        reporter.statuses = [500]
        let controller = controller()
        await controller.start(id)
        wall = wall.addingTimeInterval(600)
        uptime = 0
        bootSession = 2
        await controller.resume()
        XCTAssertNil(controller.state?.stopSource)
        XCTAssertEqual(backend.stopCalls, [])
        XCTAssertEqual(backend.scheduled, [id])
        XCTAssertEqual(reporter.calls.map(\.afterRestart), [true])
    }

    func testChangedBootSessionIsRestartEvenWithGreaterUptime() async {
        let controller = controller()
        await controller.start(id)
        wall = wall.addingTimeInterval(600)
        uptime = 60
        bootSession = 2
        await controller.resume()
        XCTAssertEqual(reporter.calls.map(\.afterRestart), [true])
    }

    func testOfflineDismissalsDrainEveryPendingEvent() async {
        let defaults = try! XCTUnwrap(UserDefaults(suiteName: AgentIdentityStore.suiteName))
        pairForTransport()
        var statuses = [500, 500, 500, 200, 201, 200]
        var requests: [URLRequest] = []
        let reporter = RingAlertReporter(
            defaults: defaults,
            reporter: AlertReporter(apiBaseURL: URL(string: "https://api.example.invalid")!, hmacSecret: "hmac"),
            sender: { request in
                requests.append(request)
                return (statuses.removeFirst(), Data())
            })
        let controller = controller(reporter: reporter)
        await controller.start(id)
        await controller.process(scheduledIDs: [])
        await controller.process(scheduledIDs: [])
        await controller.process(scheduledIDs: [])
        XCTAssertEqual(reporter.pendingEvents().count, 3)
        await controller.resume()
        XCTAssertEqual(requests.count, 6)
        let keys = requests.compactMap { try? JSONSerialization.jsonObject(with: $0.httpBody!) as? [String: Any] }
            .map { $0["dedupeKey"] as! String }
        XCTAssertEqual(keys.suffix(3), [
            "ring:\(id.uuidString.lowercased()):child_dismissed:1",
            "ring:\(id.uuidString.lowercased()):child_dismissed:2",
            "ring:\(id.uuidString.lowercased()):child_dismissed:3",
        ])
        await controller.resume()
        XCTAssertEqual(requests.count, 6)
    }

    func testDismissalCannotOverwriteStopAfterAwait() async {
        let controller = controller()
        await controller.start(id)
        var release: (() -> Void)?
        backend.scheduleGate = {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                release = { continuation.resume() }
            }
        }
        let dismissal = Task { await controller.process(scheduledIDs: []) }
        await Task.yield()
        await controller.stop(.parentCommand)
        release?()
        await dismissal.value
        XCTAssertNil(controller.state)
        XCTAssertEqual(reporter.calls.map(\.state), [.parentStopped])
        XCTAssertEqual(backend.scheduled, [])
    }

    func testDeliveredEventIsNotRetriedAfterRecreatedReporter() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: AgentIdentityStore.suiteName))
        pairForTransport()
        for status in [200, 201] {
            defaults.removeObject(forKey: RingAlertReporter.deliveredKey)
            defaults.removeObject(forKey: RingAlertReporter.pendingKey)
            backend = FakeRingBackend()
            store = InMemoryRingStore()
            var requests: [URLRequest] = []
            let controller = controller(reporter: transportReporter(defaults, status: status, requests: &requests))
            await controller.start(id)
            await controller.process(scheduledIDs: [])
            let recreated = controller(reporter: transportReporter(defaults, status: status, requests: &requests))
            await recreated.resume()
            XCTAssertEqual(requests.count, 1, "HTTP \(status) must not be sent again")
        }
    }

    func testPINSetupIsOfferedBeforeTheGate() {
        XCTAssertEqual(RingPINPresentation.resolve(isConfigured: false), .setup)
        XCTAssertEqual(RingPINPresentation.resolve(isConfigured: true), .gate)
    }

    func testAlarmQueryFailureDoesNotCountDismissal() async {
        let controller = controller()
        await controller.start(id)
        backend.scheduledError = TransportFailure()
        await controller.resume()
        XCTAssertEqual(controller.state?.dismissalCount, 0)
        XCTAssertEqual(backend.scheduled, [id])
        XCTAssertEqual(reporter.callCount, 0)
    }

    func testLiveStopWithoutTargetCancelsCurrentRing() async {
        let controller = controller()
        await controller.start(id)
        let handler = LiveRingCommands(controller: controller)
        let error = await handler.stopRing(targetId: nil)
        XCTAssertNil(error)
        XCTAssertEqual(backend.stopCalls, [id])
        XCTAssertEqual(reporter.calls.map(\.state), [.parentStopped])
    }
}
