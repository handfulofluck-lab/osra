import XCTest
@testable import FamilyShieldAgent

/// ADR-0034 A6 and ADR-0037 (5.5 PR B2, #372): the iPhone's capability report, groups included, built from plain
/// values so no test touches FamilyControls or UIKit. The server's strict schema (PR B1) is the other half.
///
/// Mutants: send the picker's labels uncleaned → [a label is cleaned again, direction controls included]; send more
/// than 20 groups → [at most twenty groups go out]; send `groups: []` when they could not be read →
/// [unreadable groups leave the field out]; drop the header → [the upload carries the report and the header].
final class CapabilityReportTests: XCTestCase {

    private let client = CapabilityReport.Client(version: "0.1.0", build: 7, flavour: .testflight)
    private let idA = "6F1C9A2E-0B7D-4C55-9A51-2F3C8E0D1A77"
    private let idB = "0D4B5C6A-7E8F-4A1B-9C2D-3E4F5A6B7C8D"

    private func report(screenTime: ScreenTimeStatus = .approved, location: LocationGrant = .background,
                        refresh: Bool = true, groups: [CapabilityReport.Group]? = []) -> CapabilityReport {
        CapabilityReport(client: client, screenTime: screenTime, location: location, backgroundRefreshOn: refresh,
                         groups: groups)
    }

    private func group(_ id: String, _ label: String, apps: Int = 3) -> CapabilityReport.Group {
        CapabilityReport.Group(id: id, label: label, counts: AppGroupCounts(apps: apps, categories: 1, sites: 0))
    }

    func testTheClientNamesThisBuild() throws {
        let c = try XCTUnwrap(report().json["client"] as? [String: Any])
        XCTAssertEqual(c["app"] as? String, "child-ios")
        XCTAssertEqual(c["version"] as? String, "0.1.0")
        XCTAssertEqual(c["build"] as? Int, 7)
        XCTAssertEqual(c["flavour"] as? String, "testflight")
    }

    func testGrantsUseTheThreeIOSKeys() throws {
        let g = try XCTUnwrap(report(screenTime: .denied, location: .whileInUse, refresh: false).json["grants"] as? [String: String])
        XCTAssertEqual(g, ["family_controls": "missing", "location": "granted", "background_refresh": "missing"])
        let none = try XCTUnwrap(report(location: .noAccess).json["grants"] as? [String: String])
        XCTAssertEqual(none["location"], "missing")
        XCTAssertEqual(none["family_controls"], "granted")
    }

    func testFeaturesFollowScreenTimeAndLocation() throws {
        let on = try XCTUnwrap(report().json["features"] as? [String: String])
        XCTAssertEqual(on["app_blocking"], "ready")
        XCTAssertEqual(on["screen_time"], "ready")
        XCTAssertEqual(on["web_filter"], "degraded")
        XCTAssertEqual(on["location"], "ready")
        for key in ["lock_screen", "pause_screen", "pause_internet", "uninstall_guard", "notification_scan", "call_sms_log"] {
            XCTAssertEqual(on[key], "not_supported", key)
        }
        let off = try XCTUnwrap(report(screenTime: .notDetermined, location: .whileInUse).json["features"] as? [String: String])
        XCTAssertEqual(off["app_blocking"], "unavailable")
        XCTAssertEqual(off["location"], "degraded")
        XCTAssertEqual(try XCTUnwrap(report(location: .noAccess).json["features"] as? [String: String])["location"], "unavailable")
    }

    func testGroupsGoOutAsIdLabelAndCountsOnly() throws {
        let groups = try XCTUnwrap(report(groups: [group(idA, "Games", apps: 5)]).json["groups"] as? [[String: Any]])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(Set(groups[0].keys), ["id", "label", "apps", "categories", "sites"])
        XCTAssertEqual(groups[0]["label"] as? String, "Games")
        XCTAssertEqual(groups[0]["apps"] as? Int, 5)
    }

    func testALabelIsCleanedAgainDirectionControlsIncluded() throws {
        let groups = try XCTUnwrap(report(groups: [group(idA, " Ga\u{202E}mes\n"), group(idB, "ألعاب\u{2066}")]).json["groups"] as? [[String: Any]])
        XCTAssertEqual(groups.map { $0["label"] as? String }, ["Games", "ألعاب"])
    }

    func testABadGroupIsLeftOutNotTheWholeReport() throws {
        let groups = try XCTUnwrap(report(groups: [
            group("not-a-uuid", "Games"), group(idA, "   "), group(idB, "School"), group(idB.lowercased(), "Again"),
        ]).json["groups"] as? [[String: Any]])
        XCTAssertEqual(groups.map { $0["label"] as? String }, ["School"], "bad id, empty label and a repeated id are dropped")
    }

    func testAtMostTwentyGroupsGoOut() throws {
        let many = (0..<25).map { group(UUID().uuidString, "g\($0)") }
        XCTAssertEqual((report(groups: many).json["groups"] as? [[String: Any]])?.count, 20)
    }

    func testUnreadableGroupsLeaveTheFieldOutAndNoneSendsAnEmptyList() {
        XCTAssertNil(report(groups: nil).json["groups"], "the server then keeps the last groups")
        XCTAssertEqual((report(groups: []).json["groups"] as? [[String: Any]])?.count, 0)
    }

    func testTheClientHeaderMatchesTheServersPattern() {
        XCTAssertEqual(report().clientHeader, "child-ios/0.1.0+7 (testflight)")
        var odd = report()
        odd.client.version = "1.0"
        XCTAssertNil(odd.clientHeader, "a version that is not three numbers sends no header")
    }

    func testTheReportIsValidJSON() {
        XCTAssertTrue(JSONSerialization.isValidJSONObject(report(groups: [group(idA, "Games")]).json))
    }

    func testTheUploadCarriesTheReportAndTheHeader() async throws {
        AgentIdentityStore.secrets = InMemorySecretStore()
        StubProtocol.reset()
        defer { StubProtocol.reset() }
        let identity = AgentIdentity(apiBaseURL: URL(string: "https://api.example.invalid")!, deviceToken: "device-jwt",
                                     deviceId: "dev-1", childId: "child-1", familyId: "fam-1", hmacSecret: "hmac")
        StubProtocol.response = (202, Data("{}".utf8))
        let client = LocationClient(session: StubProtocol.session)
        _ = await client.reportGrant(identity, .background, appliedRulesVersion: nil,
                                     capabilities: report(groups: [group(idA, "Games")]))
        let sent = try XCTUnwrap(StubProtocol.requests.last)
        XCTAssertEqual(sent.request.value(forHTTPHeaderField: "X-OSRA-Client"), "child-ios/0.1.0+7 (testflight)")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: sent.body) as? [String: Any])
        XCTAssertEqual(body["locationGrant"] as? String, "background")
        let caps = try XCTUnwrap(body["capabilities"] as? [String: Any])
        XCTAssertEqual((caps["groups"] as? [[String: Any]])?.first?["label"] as? String, "Games")
    }

    func testWithoutAReportTheUploadIsAsBefore() async throws {
        StubProtocol.reset()
        defer { StubProtocol.reset() }
        let identity = AgentIdentity(apiBaseURL: URL(string: "https://api.example.invalid")!, deviceToken: "device-jwt",
                                     deviceId: "dev-1", childId: "child-1", familyId: "fam-1", hmacSecret: "hmac")
        StubProtocol.response = (202, Data("{}".utf8))
        _ = await LocationClient(session: StubProtocol.session).reportGrant(identity, .background, appliedRulesVersion: nil)
        let sent = try XCTUnwrap(StubProtocol.requests.last)
        XCTAssertNil(sent.request.value(forHTTPHeaderField: "X-OSRA-Client"))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: sent.body) as? [String: Any])
        XCTAssertNil(body["capabilities"])
    }

    /// #693: a developer-signed Release build is `dev`, not TestFlight; only App Store signing removes the profile.
    func testEachKindOfBuildReportsItsFlavour() {
        typealias C = CapabilityReport.Client
        XCTAssertEqual(C.flavour(isDebug: true, hasEmbeddedProfile: true, receiptName: "sandboxReceipt"), .dev, "debug")
        XCTAssertEqual(C.flavour(isDebug: false, hasEmbeddedProfile: true, receiptName: "sandboxReceipt"), .dev,
                       "developer-signed Release on a device: has a profile and a sandbox receipt path")
        XCTAssertEqual(C.flavour(isDebug: false, hasEmbeddedProfile: true, receiptName: nil), .dev, "ad hoc")
        XCTAssertEqual(C.flavour(isDebug: false, hasEmbeddedProfile: false, receiptName: "sandboxReceipt"), .testflight)
        XCTAssertEqual(C.flavour(isDebug: false, hasEmbeddedProfile: false, receiptName: "receipt"), .appstore)
        XCTAssertEqual(C.flavour(isDebug: false, hasEmbeddedProfile: false, receiptName: nil), .appstore)
    }

    /// #693: the real build passes its real profile lookup, so the wiring cannot fall back to a constant.
    func testCurrentReadsTheEmbeddedProfile() throws {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/FamilyShieldAgent/CapabilityReport.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        XCTAssertTrue(text.contains(
            #"hasEmbeddedProfile: bundle.path(forResource: "embedded", ofType: "mobileprovision") != nil"#))
        XCTAssertTrue(text.contains("receiptName: bundle.appStoreReceiptURL?.lastPathComponent"))
    }
}
