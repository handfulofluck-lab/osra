import Foundation
import XCTest
@testable import FamilyShieldAgent

final class FakeRingCommands: RingCommandHandling {
    var error: RingCommandError?
    private(set) var startedIds: [String] = []
    private(set) var stopCalls = 0
    private(set) var stoppedIds: [String?] = []
    private(set) var consentWithdrawalCalls = 0

    func startRing(id: String) async -> RingCommandError? {
        if let error { return error }
        startedIds.append(id)
        return nil
    }

    func stopRing(targetId: String?) async -> RingCommandError? {
        stopCalls += 1
        stoppedIds.append(targetId)
        return error
    }

    func stopForConsentWithdrawal() async {
        consentWithdrawalCalls += 1
    }
}

@MainActor
final class RingCommandTests: XCTestCase {
    private let id = UUID(uuidString: "6F1C2B8E-3D4A-4E5F-9A0B-1C2D3E4F5A6B")!
    private var originalStopRing: (() -> Void)!

    override func setUp() {
        super.setUp()
        AgentIdentityStore.secrets = InMemorySecretStore()
        AgentIdentityStore.clear()
        StubProtocol.reset()
        originalStopRing = DeviceRevocation.stopRing
    }

    override func tearDown() {
        DeviceRevocation.stopRing = originalStopRing
        AgentIdentityStore.clear()
        StubProtocol.reset()
        super.tearDown()
    }

    private func pair() {
        XCTAssertTrue(AgentIdentityStore.save(AgentIdentity(
            apiBaseURL: URL(string: "https://api.example.invalid")!, deviceToken: "device-jwt", deviceId: "dev-1",
            childId: "child-1", familyId: "fam-1", hmacSecret: "hmac")))
    }

    private func json(_ object: Any) -> Data { try! JSONSerialization.data(withJSONObject: object) }

    private func respond(to commands: [[String: Any]]) {
        StubProtocol.responder = { [json] request in
            request.url?.path.hasSuffix("/commands") == true ? (200, json(commands)) : (200, json([:]))
        }
    }

    private func ack() throws -> [String: Any] {
        let request = try XCTUnwrap(StubProtocol.requests.last { $0.request.url?.path.hasSuffix("/ack") == true })
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: request.body) as? [String: Any])
    }

    func testRingAcksOnlyAfterSchedule() async throws {
        pair()
        let handler = FakeRingCommands()
        respond(to: [["id": id.uuidString.lowercased(), "type": "ring"]])
        let result = await CommandDrainer.drainNow(client: CommandClient(session: StubProtocol.session), ring: handler)
        XCTAssertEqual(result.handled, ["ring"])
        XCTAssertEqual(handler.startedIds, [id.uuidString.lowercased()])
        XCTAssertEqual(try ack()["status"] as? String, "ok")
    }

    func testUnsupportedOSIsFailedWithTypedReason() async throws {
        pair()
        let handler = FakeRingCommands()
        handler.error = .unsupportedOS
        respond(to: [["id": id.uuidString.lowercased(), "type": "ring"]])
        let result = await CommandDrainer.drainNow(client: CommandClient(session: StubProtocol.session), ring: handler)
        XCTAssertEqual(result.refused, ["ring"])
        XCTAssertEqual(try ack()["status"] as? String, "failed")
        XCTAssertEqual((try ack()["detail"] as? [String: String])?["reason"], "unsupported_os")
    }

    func testStopRingIsIdempotent() async throws {
        pair()
        let handler = FakeRingCommands()
        respond(to: [[
            "id": UUID().uuidString,
            "type": "stop_ring",
            "payload": ["ringId": id.uuidString.lowercased()],
        ]])
        let result = await CommandDrainer.drainNow(client: CommandClient(session: StubProtocol.session), ring: handler)
        XCTAssertEqual(result.handled, ["stop_ring"])
        XCTAssertEqual(handler.stopCalls, 1)
        XCTAssertEqual(handler.stoppedIds, [id.uuidString.lowercased()])
        XCTAssertEqual(try ack()["status"] as? String, "ok")
    }

    func testInvalidStopTargetIsFailed() async throws {
        pair()
        let handler = FakeRingCommands()
        handler.error = .invalidCommand
        respond(to: [[
            "id": UUID().uuidString,
            "type": "stop_ring",
            "payload": ["ringId": "not-a-uuid"],
        ]])
        let result = await CommandDrainer.drainNow(client: CommandClient(session: StubProtocol.session), ring: handler)
        XCTAssertEqual(result.refused, ["stop_ring"])
        XCTAssertEqual((try ack()["detail"] as? [String: String])?["reason"], "invalid_command")
    }

    func testNumericPayloadOnAnotherCommandDoesNotBlockRing() async throws {
        pair()
        let handler = FakeRingCommands()
        respond(to: [
            ["id": UUID().uuidString, "type": "pause", "payload": ["minutes": 5]],
            ["id": id.uuidString.lowercased(), "type": "ring"],
        ])
        let result = await CommandDrainer.drainNow(client: CommandClient(session: StubProtocol.session), ring: handler)
        XCTAssertEqual(result.handled, ["ring"])
        XCTAssertEqual(result.refused, ["pause"])
        XCTAssertEqual(handler.startedIds, [id.uuidString.lowercased()])
    }

    func testStopRingWithoutPayloadKeepsLegacyBehavior() async throws {
        pair()
        let handler = FakeRingCommands()
        respond(to: [["id": UUID().uuidString, "type": "stop_ring"]])
        let result = await CommandDrainer.drainNow(client: CommandClient(session: StubProtocol.session), ring: handler)
        XCTAssertEqual(result.handled, ["stop_ring"])
        XCTAssertEqual(handler.stoppedIds, [nil])
    }

    func testNumericStopTargetFailsWithoutStoppingCurrentRing() async throws {
        pair()
        let backend = FakeRingBackend()
        let controller = RingController(backend: backend, store: InMemoryRingStore(),
                                       history: InMemoryRingHistory(), reporter: RecordingRingReporter(),
                                       audioPlayer: FakeRingAudioPlayer())
        await controller.start(id)
        respond(to: [[
            "id": UUID().uuidString,
            "type": "stop_ring",
            "payload": ["ringId": 42],
        ]])
        let result = await CommandDrainer.drainNow(client: CommandClient(session: StubProtocol.session),
                                                   ring: LiveRingCommands(controller: controller))
        XCTAssertEqual(result.refused, ["stop_ring"])
        XCTAssertEqual((try ack()["detail"] as? [String: String])?["reason"], "invalid_command")
        XCTAssertTrue(backend.stopCalls.isEmpty)
        XCTAssertEqual(controller.state?.commandId, id)
    }

    func testRingViewChecksAlarmStateWhenBackgrounded() throws {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/FamilyShieldAgent/RingView.swift")
        let view = try String(contentsOf: source, encoding: .utf8)
        XCTAssertTrue(view.contains("if phase == .background"))
        XCTAssertTrue(view.contains("await controller.enterBackground()"))
        XCTAssertTrue(view.contains("await RingNotifier.showReturnNotification()"))
    }

    func testAgentRootViewShowsRingViewAsRootDuringAlarm() throws {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/FamilyShieldAgent/PairingView.swift")
        let view = try String(contentsOf: source, encoding: .utf8)
        XCTAssertTrue(view.contains("if ring.requiresPin"), "the root switches on the alarm state")
        XCTAssertTrue(view.contains("RingView(controller: ring)"), "the ring screen is the root view while an alarm is active")
        XCTAssertFalse(view.contains(".fullScreenCover(isPresented: Binding("), "the full-screen cover is replaced by the root switch")
        XCTAssertFalse(view.contains("get: { ring.requiresPin }"), "the old cover binding is gone")
    }

    func testRingViewPutsContinueInSafeAreaInset() throws {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/FamilyShieldAgent/RingView.swift")
        let view = try String(contentsOf: source, encoding: .utf8)
        XCTAssertTrue(view.contains(".safeAreaInset(edge: .bottom)"), "Continue rides above the keyboard")
        XCTAssertTrue(view.contains("A11yID.pinContinue"), "the bottom Continue has the fixed identifier")
        XCTAssertTrue(view.contains("disabled(pin.count < ParentPin.minLength)"), "Continue is disabled until the PIN is long enough")
    }

    func testRingViewPinGateHidesItsOwnButtons() throws {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/FamilyShieldAgent/RingView.swift")
        let view = try String(contentsOf: source, encoding: .utf8)
        let pinGateRange = try XCTUnwrap(view.range(of: "PinGateView(title: L10n.tr(\"ring_pin_title\")"))
        let endRange = try XCTUnwrap(view.range(of: ")", range: pinGateRange.upperBound..<view.endIndex))
        let pinGateCall = String(view[pinGateRange.lowerBound..<endRange.upperBound])
        XCTAssertTrue(pinGateCall.contains("showsButtons: false"), "RingView's PinGateView does not show its own Continue")
    }

    func testHomeOrBackgroundDoesNotStop() async {
        let backend = FakeRingBackend()
        let controller = RingController(backend: backend, store: InMemoryRingStore(),
                                       history: InMemoryRingHistory(), reporter: RecordingRingReporter())
        await controller.start(id)
        await controller.enterBackground()
        XCTAssertNotNil(controller.state)
        XCTAssertTrue(backend.stopCalls.isEmpty)
    }

    func testDeviceRevocationStopsWithoutAlert() async {
        let backend = FakeRingBackend()
        let reporter = RecordingRingReporter()
        let controller = RingController(backend: backend, store: InMemoryRingStore(),
                                       history: InMemoryRingHistory(), reporter: reporter)
        await controller.start(id)
        let stopped = expectation(description: "ring stopped after revocation")
        DeviceRevocation.stopRing = {
            Task { await controller.stopForUnpair(); stopped.fulfill() }
        }
        DeviceRevocation.unpair()
        await fulfillment(of: [stopped], timeout: 1)
        XCTAssertEqual(backend.stopCalls, [id])
        XCTAssertNil(controller.state)
        XCTAssertEqual(reporter.callCount, 0)
    }

    func testConsentResponseStopsWithoutAlert() async {
        pair()
        let backend = FakeRingBackend()
        let reporter = RecordingRingReporter()
        let controller = RingController(backend: backend, store: InMemoryRingStore(),
                                       history: InMemoryRingHistory(), reporter: reporter,
                                       audioPlayer: FakeRingAudioPlayer())
        await controller.start(id)
        StubProtocol.response = (428, Data("{}".utf8))
        let stopped = expectation(description: "ring stopped after consent withdrawal")
        DeviceRevocation.stopRing = {
            Task { await controller.stopForUnpair(); stopped.fulfill() }
        }
        let outcome = await RuleSyncer.syncNow(client: RuleSyncClient(session: StubProtocol.session), enforce: false)
        XCTAssertEqual(outcome, .consentWithdrawn)
        await fulfillment(of: [stopped], timeout: 1)
        XCTAssertEqual(backend.stopCalls, [id])
        XCTAssertEqual(reporter.callCount, 0)
    }
}
