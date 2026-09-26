import XCTest
@testable import FamilyShieldAgent

/// Exercises the pure pairing pieces (URL normalizer, claim-response parser,
/// identity store round-trip) so they run on macOS CI without UIKit,
/// entitlements, or a live server (spec §6/§14 test strategy).
final class PairingTests: XCTestCase {

    private let base = URL(string: "http://192.168.1.5:3000")!

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

    // MARK: - parseClaimResponse

    private func json(_ obj: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: obj)
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
        AgentIdentityStore.save(identity)
        XCTAssertTrue(AgentIdentityStore.isPaired())
        XCTAssertEqual(AgentIdentityStore.load(), identity)

        AgentIdentityStore.clear()
        XCTAssertFalse(AgentIdentityStore.isPaired())
        XCTAssertNil(AgentIdentityStore.load())
    }
}
