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
/// The cases run in name order and share the paired identity: claim, the alerts, the rules, push and commands,
/// then location.
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
        // Plan 2.7: the claim waits for the parent's Allow, which `live-api.mjs approve` gives from the
        // parent's side once it sees this claim (`platform: "ios"`, this device name).
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

    // 6. The rules the parent set (scripts/live-api.mjs setup) sync to the app group with the device token.
    func test6RulesSyncWithTheDeviceToken() async throws {
        _ = try input("OSRA_TEST_API_BASE")
        _ = try XCTUnwrap(AgentIdentityStore.load(), "the claim case did not leave a paired identity")
        let outcome = await RuleSyncer.syncNow(enforce: false)
        guard case .synced(let rules) = outcome else { return XCTFail("rule sync ended with \(outcome)") }
        XCTAssertEqual(rules.blockedBundleIdentifiers, ["com.example.blocked"])
        XCTAssertEqual(rules.screenTime.bedtimeStart, "21:30")
        let defaults = UserDefaults(suiteName: AgentIdentityStore.suiteName)
        XCTAssertEqual(defaults?.stringArray(forKey: "apps.blockedBundleIdentifiers"), ["com.example.blocked"])
        let routine = try XCTUnwrap(RuleStore.routineSchedules().first)
        XCTAssertEqual(routine.swiftWeekdays, [2, 1], "rules Mon,Sun (1,7) are Foundation weekdays 2,1")
        XCTAssertEqual(routine.blockedApps, ["com.example.game"])
    }

    // 7. The push token goes to the server with the device token (5.5 PR D). A simulator has no APNs token, so
    // this is a well-formed stand-in; the server only stores it.
    func test7PushTokenIsRegistered() async throws {
        _ = try input("OSRA_TEST_API_BASE")
        _ = try XCTUnwrap(AgentIdentityStore.load(), "the claim case did not leave a paired identity")
        let outcome = await PushTokenRegistrar.register(tokenHex: String(repeating: "5a", count: 32))
        XCTAssertEqual(outcome, .uploaded)
        let again = await PushTokenRegistrar.register(tokenHex: String(repeating: "5a", count: 32))
        XCTAssertEqual(again, .alreadyUploaded)
    }

    // 8. The command queue answers the device's ack-capable poll (5.5 PR D). Nothing is queued for a device
    // paired after its rules were set, so the answer is an empty list, and the poll is what is proven. Case 7
    // stored a token, so the poll says the server holds one (`X-Push-Token: on-file`, #383) and nothing is resent.
    func test8CommandQueueAnswersThePoll() async throws {
        _ = try input("OSRA_TEST_API_BASE")
        let identity = try XCTUnwrap(AgentIdentityStore.load(), "the claim case did not leave a paired identity")
        let poll = try await CommandClient().poll(identity)
        XCTAssertEqual(poll.commands, [])
        XCTAssertTrue(poll.serverHasPushToken, "case 7 stored a token, so the server answers on-file")
        let drained = await CommandDrainer.drainNow()
        XCTAssertFalse(drained.consentWithdrawn)
        XCTAssertFalse(drained.pushTokenResent)
    }
}

extension LiveAPITests {
    // 9. Location (5.5 PR E). The job put the simulator at a known coordinate (`simctl location`) and granted
    // Always (`simctl privacy`). The grant goes up in telemetry, and a locate_now through Core Location fetches
    // the point and uploads it before it answers `ok`. `live-api.mjs verify` reads it back as the parent from
    // `GET /v1/location/:childId/latest`.
    @MainActor
    func test9LocateNowUploadsAFixFromCoreLocation() async throws {
        _ = try input("OSRA_TEST_API_BASE")
        let lat = try XCTUnwrap(Double(try input("OSRA_TEST_LAT")))
        let lng = try XCTUnwrap(Double(try input("OSRA_TEST_LNG")))
        _ = try XCTUnwrap(AgentIdentityStore.load(), "the claim case did not leave a paired identity")
        let controller = LocationController.shared
        XCTAssertEqual(controller.grant, .background, "the job grants location-always before the run")
        let grantStatus = await controller.reportGrant()
        XCTAssertEqual(grantStatus, 202, "the telemetry route answers 202 Accepted")
        let ack = await controller.locateNow()
        guard case .ok(let fix)? = ack else { return XCTFail("locate_now answered \(String(describing: ack))") }
        // `ok` is only answered after the server stored the point; `verify` reads it back as the parent. The buffer
        // is not asserted empty: a fix that arrives after the 10 s wait is recorded as an ordinary update and may
        // be in flight at this line (run 40271149714, fix=cached on a slow runner).
        print("live case 9: locate_now fix=\(fix), the simulator sits at \(lat),\(lng)")
    }
}

/// Ends a case whose required live input is missing, after the failure is recorded.
private struct MissingLiveInput: Error {
    let name: String
}
