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
    var scheduleErrorID: UUID?
    var stopError: Error?
    var scheduledError: Error?
    var scheduleGate: (() async -> Void)?
    var stopGate: (() async -> Void)?
    private var continuation: AsyncStream<Set<UUID>>.Continuation?

    init(available: Bool = true, authorized: Bool = true) {
        self.available = available
        self.authorized = authorized
    }

    func requestAuthorization() async -> Bool {
        authorizationCalls += 1
        return authorized
    }

    var scheduleUntil: [UUID: Date?] = [:]
    var sentinelIDsForCommand: [UUID: Set<UUID>] = [:]
    private(set) var cancelSentinelsCalls: [UUID] = []
    var alertingIDs: Set<UUID> = []
    var bufferedScheduleSnapshots: [Set<UUID>] = []
    private var pendingUpdates: [Set<UUID>] = []

    func schedule(_ id: UUID, until: Date? = nil) async throws {
        if let scheduleError, scheduleErrorID == nil || scheduleErrorID == id { throw scheduleError }
        if let scheduleGate { await scheduleGate() }
        if !bufferedScheduleSnapshots.isEmpty {
            pendingUpdates.append(contentsOf: bufferedScheduleSnapshots)
            bufferedScheduleSnapshots.removeAll()
        }
        scheduled.append(id)
        scheduleUntil[id] = until
    }

    func stop(_ id: UUID) async throws {
        if let stopError { throw stopError }
        if let stopGate { await stopGate() }
        stopCalls.append(id)
        scheduled.removeAll { alarmIDs(for: id).contains($0) }
    }

    func isAlerting(_ id: UUID) async -> Bool {
        alertingIDs.contains(id)
    }

    func cancelSentinels(for id: UUID) async {
        cancelSentinelsCalls.append(id)
        let sentinels = sentinelIDsForCommand[id] ?? []
        scheduled.removeAll { sentinels.contains($0) }
    }

    func scheduledIDs() async throws -> Set<UUID> {
        if let scheduledError { throw scheduledError }
        return Set(scheduled)
    }

    func updates() async -> AsyncStream<Set<UUID>> {
        AsyncStream { continuation = $0 }
    }

    func emit() { emit(Set(scheduled)) }
    func emit(_ ids: Set<UUID>) { continuation?.yield(ids) }
    func flushBufferedUpdates() {
        for ids in pendingUpdates { continuation?.yield(ids) }
        pendingUpdates.removeAll()
    }

    private func alarmIDs(for commandId: UUID, until: Date? = nil) -> Set<UUID> {
        Set([commandId] + (sentinelIDsForCommand[commandId] ?? []))
    }
}

@MainActor
final class RingControllerTests: XCTestCase {
    private let id = UUID(uuidString: "6F1C2B8E-3D4A-4E5F-9A0B-1C2D3E4F5A6B")!
    private var backend: FakeRingBackend!
    private var store: InMemoryRingStore!
    private var history: InMemoryRingHistory!
    private var reporter: RecordingRingReporter!
    private var audioPlayer: FakeRingAudioPlayer!
    private var wall = Date(timeIntervalSince1970: 1_000)
    private var uptime = 10.0
    private var bootSession: TimeInterval = 1
    private var clockDriving = false

    override func setUp() {
        super.setUp()
        backend = FakeRingBackend()
        store = InMemoryRingStore()
        history = InMemoryRingHistory()
        reporter = RecordingRingReporter()
        audioPlayer = FakeRingAudioPlayer()
        bootSession = 1
        clockDriving = false
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
                            sleep: ((TimeInterval) async throws -> Void)? = nil,
                            audio: RingAudioPlaying? = nil) -> RingController {
        RingController(backend: backend, store: store, history: history, reporter: reporter ?? self.reporter,
                       audioPlayer: audio ?? audioPlayer,
                       now: { self.wall }, monotonic: { self.uptime },
                       bootSession: { self.bootSession },
                       sleep: sleep ?? { seconds in
                           if self.clockDriving {
                               self.uptime += seconds
                           } else {
                               while !self.clockDriving {
                                   try Task.checkCancellation()
                                   await Task.yield()
                               }
                           }
                       })
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

    func testMainAlarmStillScheduledDoesNotRearmOrReport() async {
        let sentinel = UUID(uuidString: "6F1C2B8E-3D4A-4E5F-9A0B-1C2D3E4F5A6C")!
        backend.sentinelIDsForCommand[id] = [sentinel]
        let controller = controller()
        await controller.start(id)
        await controller.process(scheduledIDs: [id, sentinel])
        XCTAssertEqual(backend.scheduled, [id])
        XCTAssertEqual(controller.state?.commandId, id)
        XCTAssertEqual(controller.state?.dismissalCount, 0, "an alerting main alarm is not a dismissal")
        XCTAssertEqual(reporter.callCount, 0)
        XCTAssertTrue(backend.cancelSentinelsCalls.isEmpty,
                      "sentinels stay as the no-app dismissal fallback until the main alarm is alerting")
    }

    func testMainAlarmPresentCancelsSentinels() async {
        let sentinel = UUID(uuidString: "6F1C2B8E-3D4A-4E5F-9A0B-1C2D3E4F5A6C")!
        backend.sentinelIDsForCommand[id] = [sentinel]
        let controller = controller()
        await controller.start(id)
        backend.scheduled = [id, sentinel]
        backend.alertingIDs = [id]
        await controller.process(scheduledIDs: [id, sentinel])
        XCTAssertEqual(backend.cancelSentinelsCalls, [id])
        XCTAssertEqual(backend.scheduled, [id],
                       "a ring command must present one alarm, not the whole sentinel chain")
        XCTAssertEqual(controller.state?.dismissalCount, 0)
        XCTAssertEqual(reporter.callCount, 0)
    }

    func testDismissalWithRemainingSentinelsStillReports() async {
        let sentinel = UUID(uuidString: "6F1C2B8E-3D4A-4E5F-9A0B-1C2D3E4F5A6C")!
        backend.sentinelIDsForCommand[id] = [sentinel]
        let controller = controller()
        await controller.start(id)
        backend.scheduled = [sentinel]
        await controller.process(scheduledIDs: [sentinel])
        XCTAssertEqual(controller.state?.commandId, id)
        XCTAssertEqual(controller.state?.dismissalCount, 1,
                       "the main alarm leaving is a dismissal even when later alarms remain scheduled")
        XCTAssertEqual(reporter.calls.map(\.state), [.childDismissed])
        XCTAssertEqual(backend.stopCalls, [], "a dismissal re-arms instead of stopping the chain")
    }

    func testConsentWithdrawnReportStopsTheRing() async {
        reporter.nextOutcome = .consentWithdrawn
        let controller = controller()
        await controller.start(id)
        backend.scheduled = []
        await controller.process(scheduledIDs: [])
        XCTAssertNil(controller.state)
        XCTAssertNil(store.load())
        XCTAssertEqual(backend.stopCalls, [id])
    }

    func testStaleCancelSnapshotAfterScheduleDoesNotReport() async {
        let sentinel = UUID(uuidString: "6F1C2B8E-3D4A-4E5F-9A0B-1C2D3E4F5A6C")!
        backend.sentinelIDsForCommand[id] = [sentinel]
        let controller = controller()
        await controller.start(id)
        // A cancel snapshot from our own schedule can be delivered after schedulingCommandId clears.
        // The live backend still has the main alarm, so this is not a dismissal.
        backend.emit([sentinel])
        await flushTasks()
        XCTAssertEqual(controller.state?.commandId, id)
        XCTAssertEqual(controller.state?.dismissalCount, 0)
        XCTAssertEqual(reporter.callCount, 0)
        XCTAssertEqual(backend.scheduled, [id])
    }

    func testBufferedScheduleSnapshotsAfterStartDoNotReport() async {
        let sentinel = UUID(uuidString: "6F1C2B8E-3D4A-4E5F-9A0B-1C2D3E4F5A6C")!
        backend.sentinelIDsForCommand[id] = [sentinel]
        backend.bufferedScheduleSnapshots = [[sentinel], [id, sentinel]]
        let controller = controller()
        await controller.start(id)
        backend.flushBufferedUpdates()
        await flushTasks()
        XCTAssertEqual(controller.state?.dismissalCount, 0)
        XCTAssertEqual(reporter.callCount, 0)
        XCTAssertEqual(audioPlayer.startCalls, 1)
    }

    func testBufferedScheduleSnapshotsAfterRearmDoNotReportLoop() async {
        let sentinel = UUID(uuidString: "6F1C2B8E-3D4A-4E5F-9A0B-1C2D3E4F5A6C")!
        backend.sentinelIDsForCommand[id] = [sentinel]
        let controller = controller()
        await controller.start(id)
        backend.scheduled = []
        backend.bufferedScheduleSnapshots = [[sentinel], [id, sentinel]]
        await controller.process(scheduledIDs: [])
        XCTAssertEqual(controller.state?.dismissalCount, 1)
        XCTAssertEqual(reporter.callCount, 1)
        backend.flushBufferedUpdates()
        await flushTasks()
        XCTAssertEqual(controller.state?.dismissalCount, 1,
                       "buffered cancel/add snapshots from our own re-arm must not count again")
        XCTAssertEqual(reporter.callCount, 1)
        XCTAssertEqual(audioPlayer.startCalls, 2,
                       "one re-arm starts audio once; buffered snapshots must not restart it")
        XCTAssertEqual(backend.scheduled, [id])
    }

    func testRapidSecondDismissalWithinTheReportingWindowIsSuppressedAndRearmed() async {
        let controller = controller()
        await controller.start(id)
        backend.scheduled = []
        await controller.process(scheduledIDs: [])
        XCTAssertEqual(controller.state?.dismissalCount, 1)
        XCTAssertEqual(reporter.callCount, 1)
        backend.scheduled = []
        await controller.process(scheduledIDs: [])
        XCTAssertEqual(controller.state?.dismissalCount, 1,
                       "one action cannot produce two reports inside the reporting window")
        XCTAssertEqual(reporter.callCount, 1)
        XCTAssertTrue(backend.scheduled.contains(id),
                      "a suppressed duplicate report must still re-arm the alarm")
        uptime += RingPolicy.minimumDismissalInterval
        backend.scheduled = []
        await controller.process(scheduledIDs: [])
        XCTAssertEqual(controller.state?.dismissalCount, 2)
        XCTAssertEqual(reporter.callCount, 2)
    }

    func testDelayedAudioStartForOldRingDoesNotStopReplacementRing() async {
        let audio = GatedAudioPlayer()
        let gate = ReportGate()
        audio.startGate = { await gate.wait() }
        let controller = controller(audio: audio)
        let first = UUID()
        let second = UUID()
        let firstStart = Task { await controller.start(first) }
        while audio.startCalls == 0 { await Task.yield() }
        let secondStart = Task { await controller.start(second) }
        await secondStart.value
        XCTAssertEqual(controller.state?.commandId, second)
        let stopsBeforeRelease = audio.stopCalls
        gate.release()
        await firstStart.value
        XCTAssertEqual(controller.state?.commandId, second)
        XCTAssertEqual(audio.stopCalls, stopsBeforeRelease,
                       "the old ring's delayed audio start must not stop the replacement ring")
    }

    func testPendingDismissalReportDoesNotStartAudioAfterStop() async {
        let controller = controller()
        await controller.start(id)
        backend.scheduled = []
        let gate = ReportGate()
        reporter.reportGate = { await gate.wait() }
        let processTask = Task { await controller.process(scheduledIDs: []) }
        while !gate.started { await Task.yield() }
        reporter.reportGate = nil
        await controller.stop(.pinVerified)
        XCTAssertNil(controller.state)
        gate.release()
        await processTask.value
        XCTAssertNil(controller.state)
        XCTAssertEqual(audioPlayer.startCalls, 1, "the stale report must not restart audio after the PIN stop")
        XCTAssertEqual(audioPlayer.stopCalls, 1)
    }

    func testMultipleLockScreenDismissalsIncrementCount() async {
        let controller = controller()
        await controller.start(id)
        backend.scheduled = []
        await controller.process(scheduledIDs: [])
        XCTAssertEqual(controller.state?.dismissalCount, 1)
        uptime += RingPolicy.minimumDismissalInterval
        backend.scheduled = []
        await controller.process(scheduledIDs: [])
        XCTAssertEqual(controller.state?.dismissalCount, 2)
        XCTAssertEqual(reporter.calls.map(\.state), [.childDismissed, .childDismissed])
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
    var reportGate: (() async -> Void)?
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
        if let reportGate { await reportGate() }
        if let nextOutcome { return nextOutcome }
        let status = statuses.count > 1 ? statuses.removeFirst() : statuses[0]
        guard status == 200 || status == 201 else { return .pending }
        delivered.insert(key)
        pending.removeAll { $0 == event }
        return .delivered
    }
}

@MainActor
final class ReportGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var started = false

    func wait() async {
        started = true
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
final class GatedAudioPlayer: RingAudioPlaying {
    private(set) var startCalls = 0
    private(set) var stopCalls = 0
    var startGate: (() async -> Void)?

    func start() async {
        startCalls += 1
        if let gate = startGate {
            startGate = nil
            await gate()
        }
    }

    func stop() async {
        stopCalls += 1
    }
}

@MainActor
extension RingControllerTests {
    func testLockScreenDismissalRearmsRingAndReportsDismissal() async {
        let controller = controller()
        await controller.start(id)
        backend.scheduled = []
        await controller.process(scheduledIDs: [])
        XCTAssertTrue(backend.stopCalls.isEmpty, "a lock-screen dismissal re-arms instead of stopping")
        XCTAssertEqual(controller.state?.commandId, id)
        XCTAssertNil(controller.state?.stopSource)
        XCTAssertEqual(controller.state?.dismissalCount, 1)
        XCTAssertEqual(reporter.calls.map(\.state), [.childDismissed])
    }

    func testDeliveredEventIsNotRetriedAfterRestart() async {
        let controller = controller()
        await controller.start(id)
        backend.scheduled = []
        await controller.process(scheduledIDs: [])
        XCTAssertEqual(reporter.callCount, 1)
        await controller.resume()
        XCTAssertEqual(reporter.callCount, 1)
    }

    func testOfflineEventRetriesWithoutADuplicateAfter200() async {
        reporter.statuses = [500, 200]
        let controller = controller()
        await controller.start(id)
        backend.scheduled = []
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

    func testWallJumpDoesNotTimeoutAndLockScreenDismissalRearmsRing() async {
        let controller = controller()
        await controller.start(id)
        wall = wall.addingTimeInterval(600)
        uptime += 30
        backend.scheduled = []
        await controller.process(scheduledIDs: [])
        XCTAssertEqual(reporter.calls.map(\.state), [.childDismissed])
        XCTAssertNil(controller.state?.stopSource)
        XCTAssertEqual(controller.state?.dismissalCount, 1)
        // The re-armed ring is still active; a later update showing the main alarm
        // scheduled again must not produce a second report.
        await controller.process(scheduledIDs: [id])
        XCTAssertEqual(reporter.calls.map(\.state), [.childDismissed])
    }

    func testParentStopIsRecordedWithoutRearm() async {
        let controller = controller()
        await controller.start(id)
        await controller.stop(.parentCommand)
        XCTAssertEqual(reporter.calls.map(\.state), [.parentStopped])
        XCTAssertNil(controller.state)
        backend.scheduled = []
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
        backend.scheduled = []
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

    func testConsentWithdrawal428DropsPendingReports() async {
        let defaults = UserDefaults(suiteName: AgentIdentityStore.suiteName)
        defaults?.removeObject(forKey: RingAlertReporter.pendingKey)
        pairForTransport()
        let reporter = RingAlertReporter(defaults: defaults, sender: { _ in (428, Data()) })
        let outcome = await reporter.report(state: .childDismissed, ringId: id, dismissalCount: 1)
        XCTAssertEqual(outcome, .consentWithdrawn)
        XCTAssertTrue(reporter.pendingEvents().isEmpty)
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
        XCTAssertTrue(ParentPinStore.set("9753"))
        for _ in 1...4 { _ = ParentPinStore.check("x") }
        XCTAssertEqual(ParentPinStore.check("x"), .locked(seconds: 30))
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
        wall = wall.addingTimeInterval(100)
        uptime = 0
        bootSession = 2
        await controller.resume()
        XCTAssertEqual(controller.state?.stopSource, nil)
        XCTAssertEqual(controller.state?.endAt, wall.addingTimeInterval(200))
        XCTAssertEqual(controller.state?.monotonicStart, uptime - 60)
        XCTAssertFalse(history.contains(id))
        XCTAssertEqual(backend.scheduled, [id], "the cancelled alarm is re-armed once")
        XCTAssertTrue(backend.stopCalls.isEmpty)
        XCTAssertEqual(reporter.calls.map(\.afterRestart), [true])
    }

    func testResumeAfterRestartCannotExtendPastOriginalCap() async {
        reporter.nextOutcome = .resume(after: 100)
        let controller = controller()
        await controller.start(id)
        wall = wall.addingTimeInterval(600)
        uptime = 0
        bootSession = 2
        // Alarms do not survive a reboot, so the backend reports no scheduled ids.
        backend.scheduled.removeAll()
        backend.scheduleUntil.removeAll()
        await controller.resume()
        XCTAssertNil(controller.state)
        XCTAssertEqual(reporter.calls.map(\.state), [.timedOut])
        XCTAssertEqual(reporter.calls.map(\.afterRestart), [true])
    }

    func testOfflineRestartRecordsAfterRestart() async {
        let controller = controller()
        await controller.start(id)
        wall = wall.addingTimeInterval(600)
        uptime = 0
        bootSession = 2
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
        bootSession = 2
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


private final class RingRequestRecorder {
    var requests: [URLRequest] = []
    var count: Int { requests.count }
    func append(_ request: URLRequest) { requests.append(request) }
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
                                   requests: RingRequestRecorder) -> RingAlertReporter {
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
        clockDriving = true
        await flushTasks()
        XCTAssertEqual(backend.stopCalls, [id])
        XCTAssertEqual(reporter.calls.map(\.state), [.timedOut])
        XCTAssertNil(controller.state)
    }

    func testDeadlineDoesNotStopAt299Point9() async {
        var firstWake = true
        let controller = controller(sleep: { seconds in
            if firstWake {
                firstWake = false
                self.uptime += min(seconds, 299.9)
            } else {
                while !Task.isCancelled { await Task.yield() }
            }
        })
        clockDriving = true
        await controller.start(id)
        uptime = 10
        await flushTasks()
        XCTAssertEqual(uptime, 309.9)
        XCTAssertTrue(backend.stopCalls.isEmpty)
        uptime = 310
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
        XCTAssertNil(store.load()?.stopSource)
        XCTAssertNil(controller.state?.stopSource)
        XCTAssertTrue(controller.requiresPin)
        backend.stopError = nil
        let retry = await controller.stop(.parentCommand)
        XCTAssertNil(retry)
        XCTAssertFalse(controller.requiresPin)
        XCTAssertEqual(backend.stopCalls, [id])
        XCTAssertEqual(reporter.calls.map(\.state), [.parentStopped])
        XCTAssertNil(controller.state)
    }

    func testPreviousCancelFailureDoesNotBlockReplacement() async {
        let controller = controller()
        let newer = UUID()
        await controller.start(id)
        backend.stopError = TransportFailure()
        let error = await controller.start(newer)
        XCTAssertNil(error)
        XCTAssertEqual(controller.state?.commandId, newer)
        XCTAssertTrue(backend.scheduled.contains(newer))
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
        wall = wall.addingTimeInterval(100)
        uptime = 0
        bootSession = 2
        await controller.resume()
        XCTAssertNil(controller.state?.stopSource)
        XCTAssertEqual(controller.state?.endAt, wall.addingTimeInterval(200))
        XCTAssertEqual(controller.state?.monotonicStart, 0)
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

    func testFailedReportIsStoredBeforeTransport() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: AgentIdentityStore.suiteName))
        let reporter = RingAlertReporter(defaults: defaults)
        let event = RingPendingEvent(state: .childDismissed, ringId: id, dismissalCount: 1, afterRestart: false)
        let data = try JSONEncoder().encode(event)
        defaults.set([data], forKey: RingAlertReporter.pendingKey)
        XCTAssertEqual(defaults.array(forKey: RingAlertReporter.pendingKey)?.count, 1)
        XCTAssertEqual(reporter.pendingEvents(), [event])
        defaults.removeObject(forKey: RingAlertReporter.pendingKey)

        let outcome = await reporter.report(state: .childDismissed, ringId: id, dismissalCount: 1)
        XCTAssertEqual(outcome, .pending)
        XCTAssertEqual(defaults.array(forKey: RingAlertReporter.pendingKey)?.count, 1)
        XCTAssertEqual(reporter.pendingEvents(), [event])
        for count in 2...3 {
            let next = await reporter.report(state: .childDismissed, ringId: id, dismissalCount: count)
            XCTAssertEqual(next, .pending)
        }
        XCTAssertEqual(defaults.array(forKey: RingAlertReporter.pendingKey)?.count, 3)
        XCTAssertEqual(reporter.pendingEvents().map(\.dismissalCount), [1, 2, 3])
    }

    func testOfflineLockScreenStopDrainsOnResume() async {
        let defaults = try! XCTUnwrap(UserDefaults(suiteName: AgentIdentityStore.suiteName))
        pairForTransport()
        var statuses = [500, 500, 200]
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
        backend.scheduled = []
        await controller.process(scheduledIDs: [])
        XCTAssertEqual(requests.count, 1)
        XCTAssertNil(defaults.stringArray(forKey: RingAlertReporter.deliveredKey))
        XCTAssertEqual(reporter.pendingEvents().map(\.dismissalCount), [1])
        await controller.resume()
        XCTAssertEqual(requests.count, 3)
        XCTAssertTrue(reporter.pendingEvents().isEmpty)
        await controller.resume()
        XCTAssertEqual(requests.count, 3)
    }

    func testLockScreenStopIsIgnoredAfterParentStop() async {
        let controller = controller()
        await controller.start(id)
        await controller.stop(.parentCommand)
        backend.scheduled = []
        await controller.process(scheduledIDs: [])
        XCTAssertNil(controller.state)
        XCTAssertEqual(reporter.calls.map(\.state), [.parentStopped])
    }

    func testDeliveredEventIsNotRetriedAfterRecreatedReporter() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: AgentIdentityStore.suiteName))
        pairForTransport()
        for status in [200, 201] {
            defaults.removeObject(forKey: RingAlertReporter.deliveredKey)
            defaults.removeObject(forKey: RingAlertReporter.pendingKey)
            backend = FakeRingBackend()
            store = InMemoryRingStore()
            let requests = RingRequestRecorder()
            let controller = controller(reporter: transportReporter(defaults, status: status, requests: requests))
            await controller.start(id)
            backend.scheduled = []
            await controller.process(scheduledIDs: [])
            let recreated = self.controller(reporter: transportReporter(defaults, status: status, requests: requests))
            await recreated.resume()
            XCTAssertEqual(requests.count, 1, "HTTP \(status) must not be sent again")
        }
    }

    func testActiveRingRequiresAnExistingPIN() {
        ParentPinStore.clear()
        XCTAssertFalse(ParentPinStore.isConfigured)
        XCTAssertEqual(RingPINPresentation.resolve(isConfigured: false), .gate)
        XCTAssertEqual(RingPINPresentation.resolve(isConfigured: true), .gate)
        XCTAssertFalse(ParentPin.verify("not-a-pin", stored: nil))
    }

    func testStartStartsAudio() async {
        let controller = controller()
        await controller.start(id)
        XCTAssertEqual(audioPlayer.startCalls, 1)
        XCTAssertEqual(audioPlayer.stopCalls, 0)
    }

    func testLockScreenDismissalRestartsAudio() async {
        let controller = controller()
        await controller.start(id)
        backend.scheduled = []
        await controller.process(scheduledIDs: [])
        XCTAssertEqual(audioPlayer.startCalls, 2, "a lock-screen dismissal re-arms and restarts audio")
        XCTAssertEqual(audioPlayer.stopCalls, 0)
    }

    func testLockScreenDismissalRearmsBackendAndReportsDismissal() async {
        let controller = controller()
        await controller.start(id)
        XCTAssertEqual(audioPlayer.startCalls, 1)
        backend.scheduled = []
        await controller.process(scheduledIDs: [])
        XCTAssertTrue(backend.stopCalls.isEmpty, "a lock-screen dismissal must not cancel the ring")
        XCTAssertEqual(controller.state?.commandId, id)
        XCTAssertNil(controller.state?.stopSource)
        XCTAssertEqual(controller.state?.dismissalCount, 1)
        XCTAssertEqual(reporter.calls.map(\.state), [.childDismissed])
        XCTAssertEqual(audioPlayer.startCalls, 2)
        XCTAssertEqual(audioPlayer.stopCalls, 0)
    }

    func testParentStopStopsAudio() async {
        let controller = controller()
        await controller.start(id)
        await controller.stop(.parentCommand)
        XCTAssertEqual(audioPlayer.startCalls, 1)
        XCTAssertEqual(audioPlayer.stopCalls, 1)
    }

    func testPinStopStopsAudio() async {
        let controller = controller()
        await controller.start(id)
        await controller.stop(.pinVerified)
        XCTAssertEqual(audioPlayer.startCalls, 1)
        XCTAssertEqual(audioPlayer.stopCalls, 1)
    }

    func testTimeoutStopsAudio() async {
        let controller = controller()
        await controller.start(id)
        uptime += 300
        clockDriving = true
        await flushTasks()
        XCTAssertEqual(audioPlayer.startCalls, 1)
        XCTAssertEqual(audioPlayer.stopCalls, 1)
    }

    func testUnpairStopsAudio() async {
        let controller = controller()
        await controller.start(id)
        await controller.stopForUnpair()
        XCTAssertEqual(audioPlayer.startCalls, 1)
        XCTAssertEqual(audioPlayer.stopCalls, 1)
    }

    func testConsentWithdrawalStopsAudio() async {
        let controller = controller()
        await controller.start(id)
        await controller.stopForConsentWithdrawal()
        XCTAssertEqual(audioPlayer.startCalls, 1)
        XCTAssertEqual(audioPlayer.stopCalls, 1)
    }

    func testLockScreenDismissalFollowedByLaunchDoesNotRearmAgain() async {
        let controller = controller()
        await controller.start(id)
        backend.scheduled = []
        await controller.process(scheduledIDs: [])
        XCTAssertTrue(backend.stopCalls.isEmpty)
        XCTAssertEqual(audioPlayer.startCalls, 2)
        let scheduleCountAfterDismissal = backend.scheduled.count
        let resumed = self.controller()
        await resumed.resume()
        XCTAssertEqual(backend.scheduled.count, scheduleCountAfterDismissal,
                       "resume must not schedule again when the ring is already re-armed")
        XCTAssertNil(resumed.state?.stopSource)
    }

    func testStopCancelsSentinelAlarms() async {
        let sentinel = UUID(uuidString: "6F1C2B8E-3D4A-4E5F-9A0B-1C2D3E4F5A6C")!
        backend.sentinelIDsForCommand[id] = [sentinel]
        backend.scheduled = [id, sentinel]
        let controller = controller()
        await controller.start(id)
        XCTAssertEqual(backend.scheduled, [id, sentinel, id])
        await controller.stop(.parentCommand)
        XCTAssertTrue(backend.scheduled.isEmpty, "stop must remove every alarm id for the command")
    }

    func testRearmAfterRestartCapsAtOriginalCommandWindow() async {
        reporter.nextOutcome = .resume(after: 240)
        let controller = controller()
        await controller.start(id)
        wall = wall.addingTimeInterval(100)
        uptime = 0
        bootSession = 2
        await controller.resume()
        XCTAssertEqual(controller.state?.endAt, wall.addingTimeInterval(200),
                       "a server resume cannot extend past the original 5-minute cap")
    }

    func testResumeRestartsAudio() async {
        await controller().start(id)
        let resumed = self.controller()
        await resumed.resume()
        XCTAssertGreaterThan(audioPlayer.startCalls, 0)
        XCTAssertEqual(audioPlayer.stopCalls, 0)
    }

    func testAudioPlayerLoopsRingSound() throws {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/FamilyShieldAgent/RingAudioPlayer.swift")
        let code = try String(contentsOf: source, encoding: .utf8)
        XCTAssertTrue(code.contains("numberOfLoops = -1"), "the ring sound must loop until explicitly stopped")
        XCTAssertTrue(code.contains("guard player?.isPlaying != true"),
                      "a re-arm must not recreate the audio player while the ring is already audible")
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

    func testColdStartCancelFailureDoesNotBlockReplacement() async {
        let previous = UUID()
        let replacement = UUID()
        backend.scheduled = [previous]
        backend.stopError = TransportFailure()
        store.save(RingState(commandId: previous, startedAt: wall,
                             endAt: wall.addingTimeInterval(300), monotonicStart: uptime, bootSession: 1))
        let controller = controller()
        let error = await controller.start(replacement)
        XCTAssertNil(error)
        XCTAssertTrue(backend.scheduled.contains(replacement))
    }

    func testActiveRingReplayKeepsOriginalDeadline() async {
        let controller = controller()
        await controller.start(id)
        let originalEnd = store.load()?.endAt
        wall = wall.addingTimeInterval(60)
        let error = await controller.start(id)
        XCTAssertNil(error)
        XCTAssertEqual(store.load()?.endAt, originalEnd)
        XCTAssertEqual(backend.scheduled, [id])
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
