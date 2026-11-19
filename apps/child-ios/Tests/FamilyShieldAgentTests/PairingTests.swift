import XCTest
@testable import FamilyShieldAgent

/// Exercises the pure pairing pieces (URL normalizer, claim-response parser,
/// identity store round-trip) so they run on macOS CI without UIKit,
/// entitlements, or a live server (spec §6/§14 test strategy).
final class PairingTests: XCTestCase {

    private let base = URL(string: "http://192.168.1.5:3000")!

    // The unsigned test bundle cannot reach the simulator Keychain (see AgentIdentityStoreTests).
    override func setUp() {
        super.setUp()
        AgentIdentityStore.secrets = InMemorySecretStore()
        AgentIdentityStore.clear()
    }

    override func tearDown() {
        AgentIdentityStore.clear()
        super.tearDown()
    }

    // MARK: - normalizeServerURL

    func testNormalizeAddsSchemeAndTrimsSlashes() {
        let url = PairingClient.normalizeServerURL("  192.168.1.5:3000/// ")
        XCTAssertEqual(url?.absoluteString, "http://192.168.1.5:3000")
    }

    func testNormalizeKeepsExplicitScheme() {
        let url = PairingClient.normalizeServerURL("https://osra.example.com")
        XCTAssertEqual(url?.absoluteString, "https://osra.example.com")
    }

    func testNormalizeRejectsEmptyAndNonHTTP() {
        XCTAssertNil(PairingClient.normalizeServerURL("   "))
        XCTAssertNil(PairingClient.normalizeServerURL("ftp://example.com"))
        XCTAssertNil(PairingClient.normalizeServerURL("not a url at all"))
    }

    // MARK: - claimPayload (#775)

    // Mutant: sending the Mac's platform, or any capabilities, from the default claim. The iPhone's body must stay
    // exactly the four fields it has sent since 5.5.
    func testTheDefaultClaimIsTheIPhonesUnchanged() {
        let payload = PairingClient.claimPayload(code: "123456", deviceName: "  Sara's iPhone ", device: .thisPhone())
        XCTAssertEqual(payload["platform"] as? String, "ios")
        XCTAssertEqual(payload["code"] as? String, "123456")
        XCTAssertEqual(payload["deviceName"] as? String, "Sara's iPhone")
        XCTAssertEqual(Set(payload.keys), ["code", "platform", "model", "osVersion", "deviceName"])
        XCTAssertNil(PairingClient.ClaimDevice.thisPhone().clientHeader)
    }

    // Mutant: dropping `device.platform` (hard-coding "ios") or the capability report from the body.
    func testAClaimCarriesTheDeviceItIsGiven() {
        let mac = PairingClient.ClaimDevice(platform: "macos", model: "Mac14,2", osVersion: "27.2.0",
                                            capabilities: ["client": ["app": "agent-macos"]],
                                            clientHeader: "agent-macos/0.1.0+1 (dev)")
        let payload = PairingClient.claimPayload(code: "654321", deviceName: "   ", device: mac)
        XCTAssertEqual(payload["platform"] as? String, "macos")
        XCTAssertEqual(payload["model"] as? String, "Mac14,2")
        XCTAssertEqual(payload["osVersion"] as? String, "27.2.0")
        XCTAssertNil(payload["deviceName"], "a blank name is left out")
        XCTAssertEqual((payload["capabilities"] as? [String: [String: String]])?["client"]?["app"], "agent-macos")
    }

    // MARK: - parseClaimResponse

    private func json(_ obj: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: obj)
    }

    // #602: the server's childName, trimmed; missing or blank is no name.
    func testParsesTheChildsName() {
        let base = ["device": ["id": "dev-1"], "token": "jwt", "childId": "child-1"] as [String: Any]
        var withName = base; withName["childName"] = "  Alex "
        XCTAssertEqual(PairingClient.parseClaimResponse(json(withName), baseURL: self.base)?.childName, "Alex")
        XCTAssertNil(PairingClient.parseClaimResponse(json(base), baseURL: self.base)?.childName, "a server before #602")
        var blank = base; blank["childName"] = "   "
        XCTAssertNil(PairingClient.parseClaimResponse(json(blank), baseURL: self.base)?.childName)
        var null = base; null["childName"] = NSNull()
        XCTAssertNil(PairingClient.parseClaimResponse(json(null), baseURL: self.base)?.childName)
    }

    func testParsesObjectDeviceWithHmacSecret() {
        let data = json([
            "device": ["id": "dev-1", "platform": "ios"],
            "token": "jwt-token",
            "childId": "child-1",
            "familyId": "fam-1",
            "hmacSecret": "secret-1",
        ])
        let id = PairingClient.parseClaimResponse(data, baseURL: base)
        XCTAssertEqual(id?.deviceToken, "jwt-token")
        XCTAssertEqual(id?.deviceId, "dev-1")
        XCTAssertEqual(id?.childId, "child-1")
        XCTAssertEqual(id?.familyId, "fam-1")
        XCTAssertEqual(id?.hmacSecret, "secret-1")
        XCTAssertEqual(id?.apiBaseURL, base)
    }

    func testParsesStringDeviceAndToleratesMissingSecret() {
        let data = json(["device": "dev-2", "token": "jwt-2", "childId": "child-2"])
        let id = PairingClient.parseClaimResponse(data, baseURL: base)
        XCTAssertEqual(id?.deviceId, "dev-2")
        XCTAssertNil(id?.hmacSecret) // missing -> nil (alerts then fail closed at the API)
        XCTAssertEqual(id?.familyId, "") // familyId optional in the response
    }

    func testParsesNullHmacSecretAsNil() {
        let data = json(["device": ["id": "dev-3"], "token": "jwt-3", "childId": "child-3", "hmacSecret": NSNull()])
        let id = PairingClient.parseClaimResponse(data, baseURL: base)
        XCTAssertNotNil(id)
        XCTAssertNil(id?.hmacSecret)
    }

    func testRejectsUnusableResponses() {
        XCTAssertNil(PairingClient.parseClaimResponse(json(["token": "jwt"]), baseURL: base))          // no childId
        XCTAssertNil(PairingClient.parseClaimResponse(json(["childId": "c", "token": ""]), baseURL: base)) // empty token
        XCTAssertNil(PairingClient.parseClaimResponse(Data("not json".utf8), baseURL: base))            // garbage
    }

    /// #760: notification authorization must be requested at pairing, not only when the app goes to the
    /// background during a ring. Otherwise iOS drops the first background ring push before the child has
    /// ever seen a ring screen.
    func testPairingRequestsNotificationPermission() throws {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/FamilyShieldAgent/PairingView.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        // The call must sit in the onPaired closure, after the identity is saved and before the first sync.
        XCTAssertTrue(text.contains("await RingNotifier.requestPermission()"),
                      "pairing requests notification authorization so background pushes are not dropped")
    }

    // MARK: - the parent approves each new device (plan 2.7)

    func testClaimStatusesMapToWhatTheFormShows() {
        XCTAssertNil(PairingClient.claimRefusal(status: 202))
        XCTAssertEqual(PairingClient.claimRefusal(status: 404), .httpError(status: 404))
        XCTAssertEqual(PairingClient.claimRefusal(status: 409), .alreadyClaimed)
        XCTAssertEqual(PairingClient.claimRefusal(status: 428), .consentRequired)
        // The old flow's 201 from the claim itself is not a pairing any more.
        XCTAssertEqual(PairingClient.claimRefusal(status: 201), .httpError(status: 201))
    }

    func testParsesTheClaimTicket() {
        let ticket = PairingClient.parseClaimTicket(json(["claimId": "c-1", "pollSecret": "s-1", "expiresAt": "x"]))
        XCTAssertEqual(ticket?.claimId, "c-1")
        XCTAssertEqual(ticket?.pollSecret, "s-1")
        XCTAssertNil(PairingClient.parseClaimTicket(json(["claimId": "c-1"])))
        XCTAssertNil(PairingClient.parseClaimTicket(json(["token": "jwt", "childId": "c"])))
    }

    /// Runs the poll loop over scripted answers (a nil answer is a network error) and counts the sleeps.
    private func decide(_ answers: [(Int, Data)?], maxPolls: Int = 10) async -> (Result<Data, Error>, Int) {
        var queue = answers
        var sleeps = 0
        do {
            let data = try await PairingClient.awaitDecision(
                poll: {
                    let next: (Int, Data)? = queue.isEmpty ? (202, Data()) : queue.removeFirst()
                    guard let next else { throw URLError(.notConnectedToInternet) }
                    return next
                },
                sleep: { _ in sleeps += 1 },
                maxPolls: maxPolls
            )
            return (.success(data), sleeps)
        } catch {
            return (.failure(error), sleeps)
        }
    }

    func testPollsUntilTheParentAllows() async throws {
        let paired = json(["device": ["id": "dev-1"], "token": "jwt", "childId": "child-1"])
        let (result, sleeps) = await decide([(202, Data()), nil, (201, paired)])
        XCTAssertEqual(try result.get(), paired)
        XCTAssertEqual(sleeps, 2) // a network error is a missed poll, not an answer
    }

    func testADenyOrAnExpiryEndsTheWait() async {
        let (denied, deniedSleeps) = await decide([(202, Data()), (410, Data()), (201, Data())])
        XCTAssertEqual(denied.failureError as? PairingError, .denied)
        XCTAssertEqual(deniedSleeps, 1)
        let (expired, _) = await decide([(404, Data())])
        XCTAssertEqual(expired.failureError as? PairingError, .expired)
        let (never, neverSleeps) = await decide([], maxPolls: 4)
        XCTAssertEqual(never.failureError as? PairingError, .expired)
        XCTAssertEqual(neverSleeps, 3)
    }

    // MARK: - AgentIdentityStore round-trip

    func testStoreRoundTrip() {
        let identity = AgentIdentity(
            apiBaseURL: base,
            deviceToken: "jwt-token",
            deviceId: "dev-1",
            childId: "child-1",
            familyId: "fam-1",
            hmacSecret: "secret-1"
        )
        let saved = AgentIdentityStore.save(identity)
        XCTAssertTrue(saved)
        XCTAssertTrue(AgentIdentityStore.isPaired())
        XCTAssertEqual(AgentIdentityStore.load(), identity)

        AgentIdentityStore.clear()
        XCTAssertFalse(AgentIdentityStore.isPaired())
        XCTAssertNil(AgentIdentityStore.load())
    }
}

private extension Result {
    var failureError: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
