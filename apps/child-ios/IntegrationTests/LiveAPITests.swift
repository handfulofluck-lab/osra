import XCTest
@testable import FamilyShieldAgent

/// 5.5 PR A2 (#372): the agent against our real API, started on the macOS runner from this checkout
/// (`.github/workflows/ios-ci.yml`, job `live-api`). Target `FamilyShieldAgentIntegrationTests`, hosted by
/// the signed simulator app, so the device token and HMAC secret are stored in and read back from the real
/// Keychain, as they will be on a phone. The simulator reaches the runner's 127.0.0.1.
///
/// Inputs come from `scripts/live-api.mjs setup` as `TEST_RUNNER_OSRA_TEST_*` variables, which xcodebuild
/// hands to this process without the prefix. Without `OSRA_TEST_API_BASE` every case skips, so a local run
/// stays offline. With `OSRA_REQUIRE_LIVE=1` (set in CI) a missing input fails instead: a job that
/// silently skipped would read as green (#361).
///
/// The cases run in name order and share the paired identity: claim first, then the alerts.
final class LiveAPITests: XCTestCase {

    private static var lastAcceptedRequest: URLRequest?

    private var env: [String: String] { ProcessInfo.processInfo.environment }

    private func input(_ name: String) throws -> String {
        if let value = env[name], !value.isEmpty { return value }
        if env["OSRA_REQUIRE_LIVE"] == "1" {
            XCTFail("\(name) is not set but OSRA_REQUIRE_LIVE=1: the live API inputs did not reach the test")
            throw MissingLiveInput(name: name)
        }
        throw XCTSkip("\(name) not set: the live API test runs in CI (ios-ci.yml, job live-api)")
    }

    private func pairedReporter() throws -> (AlertReporter, String) {
        let identity = try XCTUnwrap(AgentIdentityStore.load(), "the claim case did not leave a paired identity")
        let secret = try XCTUnwrap(identity.hmacSecret, "the claim returned no HMAC secret")
        return (AlertReporter(apiBaseURL: identity.apiBaseURL, hmacSecret: secret), identity.childId)
    }

    private func reason(_ data: Data) -> String? {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["reason"] as? String
    }

    private var metadata: [String: Any] { ["run": env["OSRA_TEST_RUN_MARKER"] ?? "local"] }

    /// Polls `GET /health` until it answers 200, for up to two minutes.
    private func waitUntilReachable(_ base: URL) async throws {
        let deadline = Date().addingTimeInterval(120)
        var request = URLRequest(url: base.appendingPathComponent("health"))
        request.timeoutInterval = 10
        while true {
            if let (_, response) = try? await URLSession.shared.data(for: request),
               (response as? HTTPURLResponse)?.statusCode == 200 { return }
            guard Date() < deadline else {
                XCTFail("the simulator could not reach \(base) within 120 s")
                throw MissingLiveInput(name: "reachable API")
            }
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    // 1. The claim: `platform: "ios"`, and what comes back is stored through AgentIdentityStore.
    func test1ClaimsTheCodeAsAnIPhoneAndStoresTheIdentity() async throws {
        // Read outside XCTUnwrap: an XCTSkip thrown inside its autoclosure is recorded as a failure, so the
        // case would report skipped and failed at once (found by Claude on #379, fault M4).
        let baseString = try input("OSRA_TEST_API_BASE")
        let base = try XCTUnwrap(URL(string: baseString))
        let code = try input("OSRA_TEST_PAIR_CODE")
        let childId = try input("OSRA_TEST_CHILD_ID")

        // A freshly booted simulator's first request can stall for tens of seconds. Wait until the API answers
        // /health before claiming: the code is single-use, so the claim itself is never retried.
        try await waitUntilReachable(base)
        AgentIdentityStore.clear()
        let identity = try await PairingClient().claim(baseURL: base, code: code, deviceName: "iOS live test")
        XCTAssertEqual(identity.childId, childId)
        XCTAssertFalse(identity.deviceId.isEmpty)
        XCTAssertFalse(identity.deviceToken.isEmpty)
        XCTAssertNotNil(identity.hmacSecret)
        XCTAssertTrue(AgentIdentityStore.save(identity))
        XCTAssertEqual(AgentIdentityStore.load(), identity, "read back from the Keychain and the app group")
    }

    // 2. A signed alert is accepted.
    func test2SignedAlertIsAccepted() async throws {
        _ = try input("OSRA_TEST_API_BASE")
        let (reporter, childId) = try pairedReporter()
        let request = try XCTUnwrap(reporter.makeRequest(
            category: "screen_time_exceeded", title: "Screen time limit reached",
            body: "iOS live API test", childId: childId, metadata: metadata))
        let (status, body) = try await AlertReporter.send(request)
        XCTAssertEqual(status, 201, String(decoding: body, as: UTF8.self))
        Self.lastAcceptedRequest = request
    }

    // 3. The same bytes again are a replay.
    func test3SameBytesAgainAreAReplay() async throws {
        _ = try input("OSRA_TEST_API_BASE")
        let request = try XCTUnwrap(Self.lastAcceptedRequest, "case 2 did not send an accepted alert")
        let (status, body) = try await AlertReporter.send(request)
        XCTAssertEqual(status, 401)
        XCTAssertEqual(reason(body), "replay", String(decoding: body, as: UTF8.self))
    }

    // 4. One changed byte in the body breaks the signature.
    func test4OneChangedByteIsAnInvalidSignature() async throws {
        _ = try input("OSRA_TEST_API_BASE")
        let (reporter, childId) = try pairedReporter()
        var request = try XCTUnwrap(reporter.makeRequest(
            category: "screen_time_exceeded", title: "Screen time limit reached",
            body: "iOS live API test", childId: childId, metadata: metadata))
        var bytes = try XCTUnwrap(request.httpBody)
        let index = try XCTUnwrap(bytes.firstRange(of: Data("iOS live".utf8))?.lowerBound)
        bytes[index] = UInt8(ascii: "X") // "iOS" -> "XOS": still valid JSON, no longer what was signed
        request.httpBody = bytes
        let (status, body) = try await AlertReporter.send(request)
        XCTAssertEqual(status, 401)
        XCTAssertEqual(reason(body), "invalid_signature", String(decoding: body, as: UTF8.self))
    }

    // 5. A request signed ten minutes ago is stale (the server allows 300 s of skew).
    func test5OldTimestampIsStale() async throws {
        _ = try input("OSRA_TEST_API_BASE")
        let (reporter, childId) = try pairedReporter()
        let request = try XCTUnwrap(reporter.makeRequest(
            category: "screen_time_exceeded", title: "Screen time limit reached",
            body: "iOS live API test", childId: childId, metadata: metadata,
            signedAt: Int(Date().timeIntervalSince1970) - 600))
        let (status, body) = try await AlertReporter.send(request)
        XCTAssertEqual(status, 401)
        XCTAssertEqual(reason(body), "stale_timestamp", String(decoding: body, as: UTF8.self))
    }
}

/// Ends a case whose required live input is missing, after the failure is recorded.
private struct MissingLiveInput: Error {
    let name: String
}
