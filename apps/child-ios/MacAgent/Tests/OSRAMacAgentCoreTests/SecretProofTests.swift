import XCTest
import FamilyShieldAgent
@testable import OSRAMacAgentCore

final class SecretProofTests: XCTestCase {

    private let base = URL(string: "https://api.staging.osratech.com")!

    // Mutant: counting any answer but 400 as accepted (a 200, a 202, a 404 from a proxy, a 500).
    func testOnlyA400IsAccepted() {
        XCTAssertEqual(SecretProof.outcome(status: 400, body: Data("{\"error\":{}}".utf8)), .accepted)
        for status in [0, 200, 201, 202, 204, 403, 404, 428, 429, 500, 502, 503] {
            XCTAssertEqual(SecretProof.outcome(status: status, body: nil), .inconclusive(status), "status \(status)")
        }
    }

    // Mutant: reading a wrong key as "no verdict" (the daemon would then keep asking instead of saying refused).
    func testAWrongKeyIsRefusedWithTheServersReason() {
        func answer(_ reason: String) -> Data { Data("{\"error\":\"unauthorized\",\"reason\":\"\(reason)\"}".utf8) }
        XCTAssertEqual(SecretProof.outcome(status: 401, body: answer("invalid_signature")), .refused("invalid_signature"))
        XCTAssertEqual(SecretProof.outcome(status: 401, body: answer("device_has_no_secret")), .refused("device_has_no_secret"))
        XCTAssertEqual(SecretProof.outcome(status: 401, body: answer("stale_timestamp")), .clockSkew)
        XCTAssertEqual(SecretProof.outcome(status: 401, body: answer("nonce_store_unavailable")), .inconclusive(401))
    }

    // The reason goes into the log, so only the words this client knows are repeated.
    func testAnUnknownReasonIsNotRepeated() {
        let body = Data("{\"error\":\"unauthorized\",\"reason\":\"Sara's Mac at 10.0.0.7\"}".utf8)
        XCTAssertEqual(SecretProof.outcome(status: 401, body: body), .refused("unauthorized"))
        XCTAssertEqual(SecretProof.outcome(status: 401, body: nil), .refused("unauthorized"))
        XCTAssertEqual(SecretProof.outcome(status: 401, body: Data("not json".utf8)), .refused("unauthorized"))
    }

    // Mutant: signing with anything but the device's secret, signing a different body than the one sent, or
    // adding the device token (the route would then skip the signature and the proof would prove nothing).
    func testTheRequestIsSignedOverItsOwnBodyAndCarriesNoToken() throws {
        let request = SecretProof.request(baseURL: base, deviceId: "dev-1", secret: "s3cret",
                                          unixSeconds: 1_800_000_000, nonce: "0123456789abcdef0123456789abcdef")
        XCTAssertEqual(request.url?.absoluteString, "https://api.staging.osratech.com/v1/location/ping")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let body = try XCTUnwrap(request.httpBody)
        XCTAssertEqual(String(data: body, encoding: .utf8), "{\"deviceId\":\"dev-1\",\"pings\":[]}")
        XCTAssertEqual(request.value(forHTTPHeaderField: InternalSigner.timestampHeader), "1800000000")
        XCTAssertEqual(request.value(forHTTPHeaderField: InternalSigner.nonceHeader), "0123456789abcdef0123456789abcdef")
        let expected = InternalSigner.hmacHex(
            secret: "s3cret",
            data: InternalSigner.signingBytes(timestamp: "1800000000", nonce: "0123456789abcdef0123456789abcdef", body: body))
        XCTAssertEqual(request.value(forHTTPHeaderField: InternalSigner.signatureHeader), expected)
        let wrongKey = SecretProof.request(baseURL: base, deviceId: "dev-1", secret: "another",
                                           unixSeconds: 1_800_000_000, nonce: "0123456789abcdef0123456789abcdef")
        XCTAssertNotEqual(wrongKey.value(forHTTPHeaderField: InternalSigner.signatureHeader), expected)
    }

    // Mutant: asking the server with an empty key, which signs but can never be this device's secret.
    func testAMacWithNoSecretIsRefusedWithoutARequest() async {
        let identity = AgentIdentity(apiBaseURL: URL(string: "https://unreachable.invalid")!, deviceToken: "t",
                                     deviceId: "dev-1", childId: "c", familyId: "f", hmacSecret: nil)
        let outcome = await SecretProof.check(identity)
        XCTAssertEqual(outcome, .refused("device_has_no_secret"))
    }

    // The planted fault is for the test bed only. Mutant: a normal build (this one, and CI's) that carries it, or a
    // plant that leaves the key right and so proves nothing on the device.
    func testThePlantedWrongKeyIsOffInANormalBuildAndWrongWhenOn() {
        XCTAssertFalse(SecretProof.plantedWrongKey)
        XCTAssertEqual(SecretProof.signingSecret("s3cret"), "s3cret")
        XCTAssertEqual(SecretProof.signingSecret("s3cret", planted: false), "s3cret")
        XCTAssertNotEqual(SecretProof.signingSecret("s3cret", planted: true), "s3cret")
    }

    // Pairing asks up to three times for a verdict; a refusal is final at once.
    func testPairingRetriesNoVerdictAndStopsOnARefusal() async {
        let identity = AgentIdentity(apiBaseURL: base, deviceToken: "t", deviceId: "d", childId: "c", familyId: "f",
                                     hmacSecret: "s")
        var answers: [SecretProof.Outcome] = [.inconclusive(0), .clockSkew, .accepted]
        var asked = 0
        let accepted = await AgentCLI.proveWithRetries(identity, prove: { _ in asked += 1; return answers.removeFirst() },
                                                       sleep: { _ in })
        XCTAssertEqual(accepted, .accepted)
        XCTAssertEqual(asked, 3)

        answers = [.refused("invalid_signature"), .accepted]
        asked = 0
        let refused = await AgentCLI.proveWithRetries(identity, prove: { _ in asked += 1; return answers.removeFirst() },
                                                      sleep: { _ in })
        XCTAssertEqual(refused, .refused("invalid_signature"))
        XCTAssertEqual(asked, 1)

        answers = [.inconclusive(503), .inconclusive(503), .inconclusive(503), .accepted]
        let never = await AgentCLI.proveWithRetries(identity, prove: { _ in answers.removeFirst() }, sleep: { _ in })
        XCTAssertEqual(never, .inconclusive(503), "three attempts, then pairing fails rather than guessing")
    }
}
