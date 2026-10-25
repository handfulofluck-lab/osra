import XCTest
@testable import FamilyShieldAgent

/// 5.5 PR D (#372): the command queue and the push token, against a stubbed server (`StubProtocol`).
/// The live run is `IntegrationTests/LiveAPITests` cases 7 and 8.
final class DeviceCommandsTests: XCTestCase {

    private let base = URL(string: "https://api.example.invalid")!
    private let defaults = UserDefaults(suiteName: AgentIdentityStore.suiteName)!

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

    private func pair(deviceId: String = "dev-1") {
        XCTAssertTrue(AgentIdentityStore.save(AgentIdentity(
            apiBaseURL: base, deviceToken: "device-jwt", deviceId: deviceId,
            childId: "child-1", familyId: "fam-1", hmacSecret: "hmac")))
    }

    private func json(_ object: Any) -> Data { try! JSONSerialization.data(withJSONObject: object) }

    private func ackBodies() -> [[String: Any]] {
        StubProtocol.requests.filter { $0.request.url?.path.hasSuffix("/ack") == true }
            .compactMap { try? JSONSerialization.jsonObject(with: $0.body) as? [String: Any] }
    }

    // MARK: - Which commands this agent handles

    func testRuleAndConsentCommandsSyncTheRulesAndTheRestAreRefused() {
        XCTAssertEqual(CommandAction.forType("rules_updated"), .syncRules)
        XCTAssertEqual(CommandAction.forType("consent_revoked"), .syncRules)
        XCTAssertEqual(CommandAction.forType("consent_granted"), .syncRules)
        for type in ["lock", "unlock", "ring", "pause_internet", "show_reset_code", "something_new"] {
            XCTAssertEqual(CommandAction.forType(type), .unsupported, type)
        }
    }

    // MARK: - One drain

    func testADrainSyncsOnceAcksEachCommandAndRefusesWhatItCannotDo() async {
        pair()
        StubProtocol.responder = { request in
            if request.url?.path.hasSuffix("/commands") == true {
                return (200, self.json([["id": "c1", "type": "rules_updated"], ["id": "c2", "type": "rules_updated"],
                                        ["id": "c3", "type": "lock"]]))
            }
            return (200, self.json(["command": [:]]))
        }
        var syncs = 0
        let result = await CommandDrainer.drainNow(client: CommandClient(session: StubProtocol.session)) {
            syncs += 1
            return .consentWithdrawn
        }
        XCTAssertEqual(syncs, 1, "two rules_updated in one drain cost one fetch")
        XCTAssertEqual(result.handled, ["rules_updated", "rules_updated"])
        XCTAssertEqual(result.refused, ["lock"])

        let poll = StubProtocol.requests.first?.request
        XCTAssertEqual(poll?.url?.path, "/v1/devices/dev-1/commands")
        XCTAssertEqual(poll?.url?.query, "ack=1")
        XCTAssertEqual(poll?.value(forHTTPHeaderField: "Authorization"), "Bearer device-jwt")

        let acks = ackBodies()
        XCTAssertEqual(acks.count, 3, "every command is acked")
        XCTAssertEqual(acks.map { $0["status"] as? String }, ["ok", "ok", "failed"])
        XCTAssertEqual((acks[2]["detail"] as? [String: String])?["reason"], "unsupported_on_ios",
                       "a parent sees why the iPhone did not lock, not a silent delivered")
        XCTAssertEqual(StubProtocol.requests[3].request.url?.path, "/v1/devices/dev-1/commands/c3/ack")
    }

    func testAFailedSyncIsAckedFailed() async {
        pair()
        StubProtocol.responder = { request in
            request.url?.path.hasSuffix("/commands") == true
                ? (200, self.json([["id": "c1", "type": "rules_updated"]])) : (200, self.json([:]))
        }
        _ = await CommandDrainer.drainNow(client: CommandClient(session: StubProtocol.session)) { .failed("HTTP 500") }
        XCTAssertEqual(ackBodies().first?["status"] as? String, "failed")
    }

    func testAPollAnswering428SyncsSoTheRulesAreCleared() async {
        pair()
        StubProtocol.response = (428, json(["error": "parental_consent_required"]))
        var syncs = 0
        let result = await CommandDrainer.drainNow(client: CommandClient(session: StubProtocol.session)) {
            syncs += 1
            return .consentWithdrawn
        }
        XCTAssertTrue(result.consentWithdrawn)
        XCTAssertEqual(syncs, 1)
    }

    func testUnpairedDoesNotPoll() async {
        let result = await CommandDrainer.drainNow(client: CommandClient(session: StubProtocol.session)) { .notPaired }
        XCTAssertEqual(result, CommandDrainer.Result())
        XCTAssertTrue(StubProtocol.requests.isEmpty)
    }

    // MARK: - The push token

    func testTheTokenIsLowercaseHex() {
        XCTAssertEqual(PushTokenRegistrar.hex(Data([0x00, 0xab, 0xFF, 0x10])), "00abff10")
    }

    func testTheTokenIsUploadedOncePerTokenAndDevice() async throws {
        pair()
        StubProtocol.response = (204, Data())
        let token = String(repeating: "ab", count: 32)
        let first = await PushTokenRegistrar.register(tokenHex: token, session: StubProtocol.session)
        XCTAssertEqual(first, .uploaded)
        let upload = try XCTUnwrap(StubProtocol.requests.first)
        XCTAssertEqual(upload.request.url?.path, "/v1/devices/dev-1/push-token")
        XCTAssertEqual(upload.request.httpMethod, "POST")
        XCTAssertEqual(upload.request.value(forHTTPHeaderField: "Authorization"), "Bearer device-jwt")
        XCTAssertEqual((try JSONSerialization.jsonObject(with: upload.body) as? [String: String])?["token"], token)

        let again = await PushTokenRegistrar.register(tokenHex: token, session: StubProtocol.session)
        XCTAssertEqual(again, .alreadyUploaded, "iOS hands over the token on every launch; one upload is enough")
        XCTAssertEqual(StubProtocol.requests.count, 1)

        let rotated = await PushTokenRegistrar.register(tokenHex: String(repeating: "cd", count: 32), session: StubProtocol.session)
        XCTAssertEqual(rotated, .uploaded, "a new token is uploaded")
    }

    func testARePairUploadsTheSameTokenAgain() async {
        pair(deviceId: "dev-1")
        StubProtocol.response = (204, Data())
        let token = String(repeating: "ab", count: 32)
        _ = await PushTokenRegistrar.register(tokenHex: token, session: StubProtocol.session)
        // "Re-pair this device" saves the new identity over the old one without clear() (PairingView.pair),
        // so only the device id tells the registrar that this pairing has no token on the server yet.
        pair(deviceId: "dev-2")
        let outcome = await PushTokenRegistrar.register(tokenHex: token, session: StubProtocol.session)
        XCTAssertEqual(outcome, .uploaded, "the new device row has no token yet")
        XCTAssertEqual(StubProtocol.lastRequest?.url?.path, "/v1/devices/dev-2/push-token")
    }

    func testUnpairingForgetsTheUploadedToken() async {
        pair()
        StubProtocol.response = (204, Data())
        _ = await PushTokenRegistrar.register(tokenHex: String(repeating: "ab", count: 32), session: StubProtocol.session)
        AgentIdentityStore.clear()
        XCTAssertNil(defaults.string(forKey: PushTokenRegistrar.Keys.uploadedToken))
        XCTAssertNil(defaults.string(forKey: PushTokenRegistrar.Keys.uploadedForDevice))
    }

    func testAFailedUploadIsRetriedNextTime() async {
        pair()
        StubProtocol.response = (500, Data())
        let token = String(repeating: "ab", count: 32)
        let failed = await PushTokenRegistrar.register(tokenHex: token, session: StubProtocol.session)
        XCTAssertEqual(failed, .failed(500))
        StubProtocol.response = (204, Data())
        let retried = await PushTokenRegistrar.register(tokenHex: token, session: StubProtocol.session)
        XCTAssertEqual(retried, .uploaded)
    }

    func testUnpairedDoesNotUpload() async {
        let outcome = await PushTokenRegistrar.register(tokenHex: "ab", session: StubProtocol.session)
        XCTAssertEqual(outcome, .notPaired)
        XCTAssertTrue(StubProtocol.requests.isEmpty)
    }
}
