import XCTest
@testable import FamilyShieldAgent

/// #760: the notification service extension's reduced drain. A physical-device row proved a priority-5
/// background push cannot wake a locked/suspended/force-quit iPhone, so the server's ring push is a
/// visible alert and the extension answers it with one short poll, `ring` only: every other command is
/// left un-acked for the app's full drain, and a started-vs-fallback outcome decides nothing about the
/// notification itself — localized content is delivered on every path. `FakeRingCommands` is the
/// `RingCommandTests` fake; the live run is the Mac test bed's ring rows.
final class RingPushDrainTests: XCTestCase {

    private let base = URL(string: "https://api.example.invalid")!
    private let ringId = "6F1C2B8E-3D4A-4E5F-9A0B-1C2D3E4F5A6B"

    override func setUp() {
        super.setUp()
        AgentIdentityStore.secrets = InMemorySecretStore()
        AgentIdentityStore.clear()
        StubProtocol.reset()
    }

    override func tearDown() {
        AgentIdentityStore.clear()
        StubProtocol.reset()
        super.tearDown()
    }

    private func pair() {
        XCTAssertTrue(AgentIdentityStore.save(AgentIdentity(
            apiBaseURL: base, deviceToken: "device-jwt", deviceId: "dev-1",
            childId: "child-1", familyId: "fam-1", hmacSecret: "hmac")))
    }

    private func json(_ object: Any) -> Data { try! JSONSerialization.data(withJSONObject: object) }

    private func respond(to commands: [[String: Any]]) {
        StubProtocol.responder = { [json] request in
            request.url?.path.hasSuffix("/commands") == true ? (200, json(commands)) : (200, json([:]))
        }
    }

    private func acks() -> [(request: URLRequest, body: Data)] {
        StubProtocol.requests.filter { $0.request.url?.path.hasSuffix("/ack") == true }
    }

    // MARK: - Only ring, with a short poll

    func testARingCommandStartsAndAcksOk() async throws {
        pair()
        respond(to: [["id": ringId, "type": "ring"]])
        let ring = FakeRingCommands()
        let outcome = await RingPushDrainer.drainNow(client: CommandClient(session: StubProtocol.session), ring: ring)
        XCTAssertEqual(outcome, .started)
        XCTAssertEqual(ring.startedIds, [ringId])
        let ack = try XCTUnwrap(acks().first)
        XCTAssertEqual(ack.request.url?.path, "/v1/devices/dev-1/commands/\(ringId)/ack")
        XCTAssertEqual((try JSONSerialization.jsonObject(with: ack.body) as? [String: Any])?["status"] as? String, "ok")
    }

    func testThePollUsesTheShortTimeout() async throws {
        pair()
        StubProtocol.response = (200, json([]))
        _ = await RingPushDrainer.drainNow(client: CommandClient(session: StubProtocol.session), ring: FakeRingCommands())
        let poll = try XCTUnwrap(StubProtocol.requests.first { $0.request.url?.path.hasSuffix("/commands") == true })
        XCTAssertEqual(poll.request.timeoutInterval, RingPushDrainer.pollTimeoutSeconds)
        XCTAssertLessThan(poll.request.timeoutInterval, 30, "the NSE budget is far under the app's 30-second wake deadline")
    }

    func testTheDefaultPollTimeoutRemainsThirty() async throws {
        pair()
        StubProtocol.response = (200, json([]))
        _ = try await CommandClient(session: StubProtocol.session).poll(try XCTUnwrap(AgentIdentityStore.load()))
        XCTAssertEqual(StubProtocol.lastRequest?.timeoutInterval, 30, "CommandClient stays additive: existing callers keep the 30 s deadline")
    }

    // MARK: - Everything else is left alone

    func testEveryOtherCommandIsLeftUnAcked() async {
        pair()
        respond(to: [["id": "c1", "type": "rules_updated"], ["id": "c2", "type": "locate_now"]])
        let outcome = await RingPushDrainer.drainNow(client: CommandClient(session: StubProtocol.session), ring: FakeRingCommands())
        XCTAssertEqual(outcome, .fallback)
        XCTAssertTrue(acks().isEmpty, "non-ring commands stay un-acked for the app's full drain")
    }

    func testANonRingCommandBeforeARingIsSkippedAndTheRingIsAcked() async throws {
        pair()
        respond(to: [["id": "c1", "type": "lock"], ["id": ringId, "type": "ring"]])
        let ring = FakeRingCommands()
        let outcome = await RingPushDrainer.drainNow(client: CommandClient(session: StubProtocol.session), ring: ring)
        XCTAssertEqual(outcome, .started)
        XCTAssertEqual(ring.startedIds, [ringId])
        XCTAssertEqual(acks().count, 1, "exactly the ring is acked")
        XCTAssertEqual(acks().first?.request.url?.path, "/v1/devices/dev-1/commands/\(ringId)/ack")
    }

    // MARK: - Every failure answers fallback

    func testAScheduleFailureFallsBackWithoutAcks() async {
        pair()
        respond(to: [["id": ringId, "type": "ring"]])
        let ring = FakeRingCommands()
        ring.error = .unsupportedOS
        let outcome = await RingPushDrainer.drainNow(client: CommandClient(session: StubProtocol.session), ring: ring)
        XCTAssertEqual(outcome, .fallback, "a failed schedule never suppresses the localized notification")
        XCTAssertTrue(acks().isEmpty, "the extension must never mark the ring command as failed; the app's full drain handles it")
    }

    func testAPollFailureFallsBackWithoutAcks() async {
        pair()
        StubProtocol.response = (500, Data())
        let outcome = await RingPushDrainer.drainNow(client: CommandClient(session: StubProtocol.session), ring: FakeRingCommands())
        XCTAssertEqual(outcome, .fallback)
        XCTAssertTrue(acks().isEmpty)
    }

    func testConsentRequiredFallsBackWithoutAcks() async {
        pair()
        StubProtocol.response = (428, json(["error": "parental_consent_required"]))
        let outcome = await RingPushDrainer.drainNow(client: CommandClient(session: StubProtocol.session), ring: FakeRingCommands())
        XCTAssertEqual(outcome, .fallback)
        XCTAssertTrue(acks().isEmpty)
    }

    func testUnpairedFallsBackWithoutPolling() async {
        let outcome = await RingPushDrainer.drainNow(client: CommandClient(session: StubProtocol.session), ring: FakeRingCommands())
        XCTAssertEqual(outcome, .fallback)
        XCTAssertTrue(StubProtocol.requests.isEmpty)
    }

    // MARK: - The service extension's half, guarded here because the extension module is iOS-only

    func testTheServiceExtensionAlwaysBuildsLocalizedFallbackContent() throws {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Extensions/RingService/RingServiceExtension.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        XCTAssertTrue(text.contains("UNNotificationServiceExtension"))
        XCTAssertTrue(text.contains("RingPushDrainer.drainNow"), "the extension answers the push through the reduced drain")
        XCTAssertTrue(text.contains(#"L10n.tr("ring_notification_title")"#), "the approved title, never OSRA text")
        XCTAssertTrue(text.contains(#"L10n.tr("ring_notification_body")"#), "the approved body, never OSRA text")
        XCTAssertTrue(text.contains("let outcome = await RingPushDrainer.drainNow()"))
        XCTAssertTrue(text.contains("deliver(content, ringSound: outcome == .started)"))
        XCTAssertTrue(text.contains("if ringSound {"))
        XCTAssertTrue(text.contains("content.sound = .defaultRingtone"), "a started ring rings")
        XCTAssertTrue(text.contains("} else {\n            content.sound = .default\n        }"),
                      "the approved fallback keeps the default sound")
        XCTAssertTrue(text.contains("serviceExtensionTimeWillExpire"), "the timeout path still delivers")
        XCTAssertTrue(text.contains("deliver(bestAttemptContent ?? UNMutableNotificationContent(), ringSound: false)"),
                      "the deadline path is the approved default-sound fallback")
    }
}
