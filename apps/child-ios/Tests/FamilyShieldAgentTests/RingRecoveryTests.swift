import Foundation
import XCTest
@testable import FamilyShieldAgent

@MainActor
final class RingRecoveryTests: XCTestCase {
    private let id = UUID(uuidString: "6F1C2B8E-3D4A-4E5F-9A0B-1C2D3E4F5A6B")!
    private var backend: FakeRingBackend!
    private var store: InMemoryRingStore!
    private var history: InMemoryRingHistory!
    private var reporter: RecordingRingReporter!
    private var audioPlayer: FakeRingAudioPlayer!
    private var wall = Date(timeIntervalSince1970: 1_000)
    private var uptime = 10.0
    private var bootSession = 1.0
    private var clockDriving = false

    override func setUp() {
        super.setUp()
        backend = FakeRingBackend()
        store = InMemoryRingStore()
        history = InMemoryRingHistory()
        reporter = RecordingRingReporter()
        audioPlayer = FakeRingAudioPlayer()
        AgentIdentityStore.secrets = InMemorySecretStore()
        AgentIdentityStore.clear()
        ParentPinStore.clear()
    }

    override func tearDown() {
        let defaults = UserDefaults(suiteName: AgentIdentityStore.suiteName)
        defaults?.removeObject(forKey: RingAlertReporter.deliveredKey)
        defaults?.removeObject(forKey: RingAlertReporter.pendingKey)
        ParentPinStore.clear()
        AgentIdentityStore.clear()
        super.tearDown()
    }

    private func controller(reporter: RingAlertReporting? = nil) -> RingController {
        RingController(backend: backend, store: store, history: history,
                       reporter: reporter ?? self.reporter,
                       audioPlayer: audioPlayer,
                       now: { self.wall }, monotonic: { self.uptime },
                       bootSession: { self.bootSession },
                       sleep: { seconds in
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

    private func waitForGate(_ opened: () -> Bool) async {
        for _ in 0..<20 {
            if opened() { return }
            await Task.yield()
        }
        XCTFail("the asynchronous gate was not reached")
    }

    private func pairForTransport() {
        XCTAssertTrue(AgentIdentityStore.save(AgentIdentity(
            apiBaseURL: URL(string: "https://api.example.invalid")!, deviceToken: "device-jwt", deviceId: "dev-1",
            childId: "child-1", familyId: "fam-1", hmacSecret: "hmac")))
    }

    private func transportReporter(defaults: UserDefaults, status: Int) -> RingAlertReporter {
        RingAlertReporter(defaults: defaults,
                          reporter: AlertReporter(apiBaseURL: URL(string: "https://api.example.invalid")!, hmacSecret: "hmac"),
                          sender: { _ in (status, Data()) })
    }

    func testCancellationFailureRestoresOriginalDeadline() async {
        let controller = controller()
        await controller.start(id)
        backend.stopError = RingControllerTests.TransportFailure()
        let error = await controller.stop(.pinVerified)
        XCTAssertEqual(error, .stopFailed)
        backend.stopError = nil
        uptime += 300
        clockDriving = true
        await flushTasks()
        XCTAssertEqual(backend.stopCalls, [id])
        XCTAssertEqual(reporter.calls.map(\.state), [.timedOut])
        XCTAssertNil(controller.state)
    }

    func testPreviousCancelFailureDoesNotBlockReplacement() async {
        let replacement = UUID()
        let controller = controller()
        await controller.start(id)
        backend.stopError = RingControllerTests.TransportFailure()
        let error = await controller.start(replacement)
        XCTAssertNil(error)
        XCTAssertEqual(controller.state?.commandId, replacement)
        XCTAssertTrue(backend.scheduled.contains(replacement))
        backend.stopError = nil
        uptime += 300
        clockDriving = true
        await flushTasks()
        XCTAssertEqual(backend.stopCalls, [replacement])
        XCTAssertEqual(reporter.calls.map(\.state), [.timedOut])
    }

    func testEmptyStopTargetUsesCurrentRing() async {
        let controller = controller()
        await controller.start(id)
        let error = await LiveRingCommands(controller: controller).stopRing(targetId: "")
        XCTAssertNil(error)
        XCTAssertEqual(backend.stopCalls, [id])
        XCTAssertNil(controller.state)
    }

    func testWrongStopTargetIsFailedWithoutStoppingCurrentRing() async {
        let controller = controller()
        await controller.start(id)
        let error = await LiveRingCommands(controller: controller).stopRing(targetId: UUID().uuidString)
        XCTAssertEqual(error, .invalidCommand)
        XCTAssertEqual(controller.state?.commandId, id)
        XCTAssertTrue(backend.stopCalls.isEmpty)
    }

    func testAlarmKitUsesLongerLeadTimeAndSafeErrorLogging() throws {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/FamilyShieldAgent/AlarmKitRingBackend.swift")
        let backend = try String(contentsOf: source, encoding: .utf8)
        // #760 redesign: a lead time longer than 2 s avoids the re-ring-after-dismiss race where
        // AlarmKit dropped a schedule whose fire date was already in the past.
        XCTAssertTrue(backend.contains(".fixed(fireDate)"))
        XCTAssertTrue(backend.contains("leadTime: TimeInterval = 5"))
        XCTAssertTrue(backend.contains("RingAlarmLog"))
        XCTAssertTrue(backend.contains("type(of: error)"))
        XCTAssertTrue(backend.contains("authorization state="))
        XCTAssertTrue(backend.contains("schedule fireDate="))
    }

    func testRingServiceExtensionDoesNotCallAlarmKitOrDrainer() throws {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Extensions/RingService/RingServiceExtension.swift")
        let extensionSource = try String(contentsOf: source, encoding: .utf8)
        XCTAssertFalse(extensionSource.contains("RingPushDrainer"))
        XCTAssertFalse(extensionSource.contains("AlarmKit"))
        XCTAssertFalse(extensionSource.contains("AlarmManager"))
        XCTAssertTrue(extensionSource.contains("L10n.tr(\"ring_notification_title\")"))
        XCTAssertTrue(extensionSource.contains("L10n.tr(\"ring_notification_body\")"))
    }

    func testAppEntitlementsIncludeTimeSensitiveCapability() throws {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("App/OSRAAgent.entitlements")
        let entitlements = try String(contentsOf: source, encoding: .utf8)
        XCTAssertTrue(entitlements.contains("com.apple.developer.usernotifications.time-sensitive"))
    }

    func testFailedReplacementSchedulingRestoresAlarmAndDeadline() async {
        let replacement = UUID()
        backend.scheduleError = RingControllerTests.TransportFailure()
        backend.scheduleErrorID = replacement
        let controller = controller()
        await controller.start(id)
        let error = await controller.start(replacement)
        XCTAssertEqual(error, .scheduleFailed)
        XCTAssertEqual(controller.state?.commandId, id)
        XCTAssertEqual(backend.scheduled, [id])
        backend.stopCalls = []
        uptime += 300
        clockDriving = true
        await flushTasks()
        XCTAssertEqual(backend.stopCalls, [id])
        XCTAssertEqual(reporter.calls.map(\.state), [.timedOut])
    }

    func testDeliveredRestartTimeoutCancelsScheduledAlarm() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: AgentIdentityStore.suiteName))
        pairForTransport()
        let pendingReporter = transportReporter(defaults: defaults, status: 500)
        let controller = controller(reporter: pendingReporter)
        await controller.start(id)
        let outcome = await pendingReporter.report(state: .timedOut, ringId: id,
                                                   dismissalCount: 0, afterRestart: true)
        XCTAssertEqual(outcome, .pending)
        let recreated = self.controller(reporter: transportReporter(defaults: defaults, status: 201))
        await recreated.resume()
        XCTAssertEqual(backend.stopCalls, [id])
        XCTAssertEqual(backend.scheduled, [])
        XCTAssertNil(recreated.state)
    }

    func testLateStopResponseCannotClearReplacement() async {
        let replacement = UUID()
        let controller = controller()
        await controller.start(id)
        var release: (() -> Void)?
        reporter.reportGate = {
            self.reporter.reportGate = nil
            await withCheckedContinuation { continuation in
                release = { continuation.resume() }
            }
        }
        let stopped = Task { await controller.stop(.parentCommand) }
        await waitForGate { release != nil }
        await controller.start(replacement)
        release?()
        await stopped.value
        XCTAssertEqual(controller.state?.commandId, replacement)
        XCTAssertEqual(store.load()?.commandId, replacement)
        XCTAssertEqual(backend.scheduled, [replacement])
    }

    func testUnpairDuringSchedulingCannotRestoreRing() async {
        var release: (() -> Void)?
        backend.scheduleGate = {
            await withCheckedContinuation { continuation in
                release = { continuation.resume() }
            }
        }
        let controller = controller()
        let started = Task { await controller.start(id) }
        await waitForGate { release != nil }
        await controller.stopForUnpair()
        release?()
        await started.value
        XCTAssertNil(controller.state)
        XCTAssertNil(store.load())
        XCTAssertEqual(backend.scheduled, [])
        XCTAssertFalse(history.contains(id))
    }
}
