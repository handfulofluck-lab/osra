import XCTest
import FamilyShieldAgent
@testable import OSRAMacAgentCore

/// What the Mac sends, against the server's contract: `packages/shared-types/src/capabilities.ts`,
/// `services/api/src/lib/clientHeader.ts` and `ClaimSchema` in `services/api/src/routes/devices.ts`.
final class MacAgentContractTests: XCTestCase {

    // #775: "Use the staging API only, never production." Mutant: any other host, or http.
    func testTheOnlyServerIsStagingOverHTTPS() {
        XCTAssertEqual(MacAgentServer.builtIn.absoluteString, "https://api.staging.osratech.com")
        XCTAssertTrue(MacAgentServer.isBuiltIn(URL(string: "https://API.staging.osratech.com/")!))
        for other in ["https://api.osratech.com", "http://api.staging.osratech.com", "https://api.staging.osratech.com:8443",
                      "https://api.staging.osratech.com.example.org", "https://staging.osratech.com"] {
            XCTAssertFalse(MacAgentServer.isBuiltIn(URL(string: other)!), other)
        }
    }

    // ADR-0041 D5: the pairing code only. Mutant: any option that names a server.
    func testPairingHasNoServerOption() {
        XCTAssertEqual(AgentCLI.parse(["pair", "123456"]), .pair(code: "123456", childUser: nil, deviceName: nil))
        XCTAssertEqual(AgentCLI.parse(["pair"]), .pair(code: nil, childUser: nil, deviceName: nil))
        XCTAssertEqual(AgentCLI.parse(["pair", "--child-user", "sara", "123456", "--device-name", "Study Mac"]),
                       .pair(code: "123456", childUser: "sara", deviceName: "Study Mac"))
        for refused in [["pair", "123456", "--server", "https://example.org"], ["pair", "--url=https://example.org"],
                        ["pair", "123456", "https://example.org"], ["pair", "--child-user"], ["run", "extra"], [],
                        ["pair", "-s", "x"], ["serve"]] {
            XCTAssertNil(AgentCLI.parse(refused), "\(refused)")
        }
    }

    func testAPairingCodeIsSixDigits() {
        XCTAssertTrue(AgentCLI.isPairingCode("012345"))
        for bad in ["", "12345", "1234567", "12345a", "12 345", "١٢٣٤٥٦"] { XCTAssertFalse(AgentCLI.isPairingCode(bad), bad) }
    }

    // The server's strict schema refuses an unknown key, so every word here must be in its vocabulary.
    func testTheCapabilityReportUsesOnlyTheServersVocabulary() throws {
        let report = MacCapabilityReport()
        let json = report.json
        XCTAssertEqual(Set(json.keys), ["client", "grants", "features"])
        let client = try XCTUnwrap(json["client"] as? [String: Any])
        XCTAssertEqual(client["app"] as? String, "agent-macos")
        XCTAssertEqual(client["version"] as? String, "0.1.0")
        XCTAssertEqual(client["build"] as? Int, 1)
        XCTAssertTrue(["play", "full", "dev", "testflight", "appstore"].contains(client["flavour"] as? String ?? ""))
        XCTAssertEqual(json["grants"] as? [String: String], [:])
        let featureKeys: Set<String> = ["lock_screen", "pause_screen", "app_blocking", "screen_time", "web_filter",
                                        "pause_internet", "location", "uninstall_guard", "notification_scan",
                                        "call_sms_log"]
        let features = try XCTUnwrap(json["features"] as? [String: String])
        XCTAssertTrue(Set(features.keys).isSubset(of: featureKeys))
        XCTAssertTrue(JSONSerialization.isValidJSONObject(json))
        XCTAssertLessThan(try JSONSerialization.data(withJSONObject: json).count, 4096)
    }

    // Mutant: reporting any feature "ready" or "degraded" while this step enforces nothing. The parent app would
    // then promise a block the Mac does not make.
    func testNothingIsReportedAsWorkingWhileNothingIsEnforced() throws {
        let features = try XCTUnwrap(MacCapabilityReport().json["features"] as? [String: String])
        XCTAssertFalse(features.isEmpty)
        XCTAssertEqual(Set(features.values), ["unavailable"])
    }

    // `services/api/src/lib/clientHeader.ts`, the same pattern.
    func testTheClientHeaderMatchesTheServersPattern() {
        let pattern = #"^(parent-app|child-android|child-ios|agent-desktop|agent-macos)/\d{1,4}\.\d{1,4}\.\d{1,4}\+\d{1,9} \([a-z0-9-]{1,16}\)$"#
        let header = MacCapabilityReport().clientHeader
        XCTAssertEqual(header, "agent-macos/0.1.0+1 (dev)")
        XCTAssertNotNil(header.range(of: pattern, options: .regularExpression))
    }

    // Mutant: pairing as "ios" (the shared default). The server ties `agent-macos` to platform `macos` and refuses
    // the report otherwise.
    func testTheClaimSaysItIsAMac() {
        let device = MacDevice.claimDevice()
        XCTAssertEqual(device.platform, "macos")
        XCTAssertEqual(device.clientHeader, "agent-macos/0.1.0+1 (dev)")
        XCTAssertFalse(device.model.isEmpty)
        XCTAssertNotNil(device.osVersion.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression))
        let payload = PairingClient.claimPayload(code: "123456", deviceName: "Study Mac", device: device)
        XCTAssertEqual(payload["platform"] as? String, "macos")
        XCTAssertNotNil(payload["capabilities"])
        XCTAssertEqual(MacDevice.model(hardware: "Mac14,2"), "Mac (Mac14,2)")
        XCTAssertEqual(MacDevice.model(hardware: nil), "Mac")
    }

    // The heartbeat is the capability report with the device token; it claims no applied rules (#475).
    func testTheHeartbeatCarriesTheReportAndNoAppliedVersion() throws {
        let identity = AgentIdentity(apiBaseURL: MacAgentServer.builtIn, deviceToken: "jwt", deviceId: "dev-1",
                                     childId: "c", familyId: "f", hmacSecret: "s")
        let request = HeartbeatClient.request(identity, report: MacCapabilityReport())
        XCTAssertEqual(request.url?.absoluteString, "https://api.staging.osratech.com/v1/devices/dev-1/telemetry")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer jwt")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-OSRA-Client"), "agent-macos/0.1.0+1 (dev)")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(Set(body.keys), ["capabilities"])
    }

    // ADR-0036 rule 4. Mutant: missing group 80, or calling an account nobody could look up "standard".
    func testAnAccountInTheAdminGroupIsAnAdministrator() {
        XCTAssertEqual(ChildAccount.kind(userID: 502, groupIDs: [20, 12, 61]), .standard)
        XCTAssertEqual(ChildAccount.kind(userID: 501, groupIDs: [20, 80, 12]), .administrator)
        XCTAssertEqual(ChildAccount.kind(userID: 0, groupIDs: [0]), .administrator)
        XCTAssertEqual(ChildAccount.kind(userID: nil, groupIDs: nil), .unknown)
        XCTAssertEqual(ChildAccount.kind(userID: 502, groupIDs: nil), .unknown)
        XCTAssertEqual(ChildAccount.kind(ofUser: "root"), .administrator)
        XCTAssertEqual(ChildAccount.kind(ofUser: "no-such-account-\(UUID().uuidString.prefix(8))"), .unknown)
    }

    // The words the command line prints for each ending; never the server's own text.
    func testEveryPairingEndingHasAFixedWord() {
        XCTAssertEqual(AgentCLI.word(for: PairingError.httpError(status: 404)), "code_unknown_or_expired")
        XCTAssertEqual(AgentCLI.word(for: PairingError.httpError(status: 503)), "server_answered_503")
        XCTAssertEqual(AgentCLI.word(for: PairingError.alreadyClaimed), "code_in_use")
        XCTAssertEqual(AgentCLI.word(for: PairingError.denied), "denied_by_parent")
        XCTAssertEqual(AgentCLI.word(for: PairingError.expired), "code_expired")
        XCTAssertEqual(AgentCLI.word(for: PairingError.consentRequired), "consent_required")
        XCTAssertEqual(AgentCLI.word(for: URLError(.notConnectedToInternet)), "network")
    }
}
