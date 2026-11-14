import XCTest
@testable import FamilyShieldAgent

/// #690: a phone the parent removed gets `401 {"error":"device_revoked"}` on every device-token call, and then
/// leaves the paired state: pairing, rules, shields, unsent location and parent PIN all go. Each path that sends
/// the device token is covered, and no other 401 unpairs. The network is stubbed (`StubProtocol`).
final class DeviceRevocationTests: XCTestCase {
    private let store = InMemorySecretStore()
    private var shieldsCleared = 0
    private var platformClearShields: (() -> Void)!
    private let identity = AgentIdentity(
        apiBaseURL: URL(string: "https://api.example.invalid")!,
        deviceToken: "device-jwt",
        deviceId: "dev-1",
        childId: "child-1",
        familyId: "fam-1",
        hmacSecret: "hmac-secret"
    )

    override func setUp() {
        super.setUp()
        platformClearShields = DeviceRevocation.clearShields
        AgentIdentityStore.secrets = store
        AgentIdentityStore.clear()
        LocationBuffer.clear()
        StubProtocol.reset()
        shieldsCleared = 0
        DeviceRevocation.clearShields = { [weak self] in self?.shieldsCleared += 1 }
    }

    override func tearDown() {
        DeviceRevocation.clearShields = platformClearShields
        AgentIdentityStore.clear()
        LocationBuffer.clear()
        StubProtocol.reset()
        super.tearDown()
    }

    private func json(_ object: Any) -> Data { try! JSONSerialization.data(withJSONObject: object) }
    private var revoked: (Int, Data) { (401, json(["error": "device_revoked"])) }

    /// Paired, with a parent PIN and a stored bedtime, as the removed family left it.
    private func pairWithRules() {
        XCTAssertTrue(AgentIdentityStore.save(identity))
        store.write("pbkdf2$1$AA==$AA==", for: ParentPinStore.account)
        UserDefaults(suiteName: AgentIdentityStore.suiteName)?.set("21:00", forKey: "rules.bedtimeStart")
        LocationBuffer.append([LocationPing(lat: 1, lng: 2, accuracyM: 5, timestamp: Date())])
    }

    private func assertUnpaired(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(AgentIdentityStore.load(), "pairing gone", file: file, line: line)
        XCTAssertNil(store.read(AgentIdentityStore.Keys.deviceToken), "device token gone", file: file, line: line)
        XCTAssertNil(store.read(ParentPinStore.account), "parent PIN gone", file: file, line: line)
        XCTAssertNil(RuleStore.bedtimeStart(), "rules gone", file: file, line: line)
        XCTAssertTrue(LocationBuffer.load().isEmpty, "unsent location gone", file: file, line: line)
        XCTAssertEqual(shieldsCleared, 1, "shields lifted once", file: file, line: line)
    }

    private func assertStillPaired(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(AgentIdentityStore.load(), identity, file: file, line: line)
        XCTAssertNotNil(store.read(ParentPinStore.account), file: file, line: line)
        XCTAssertEqual(shieldsCleared, 0, file: file, line: line)
    }

    func testOnlyTheServersDeviceRevokedAnswerCounts() {
        XCTAssertTrue(DeviceRevocation.isRevoked(status: 401, body: json(["error": "device_revoked"])))
        XCTAssertFalse(DeviceRevocation.isRevoked(status: 401, body: json(["error": "session_revoked"])))
        XCTAssertFalse(DeviceRevocation.isRevoked(status: 401, body: json(["error": "invalid_signature"])))
        XCTAssertFalse(DeviceRevocation.isRevoked(status: 401, body: Data()))
        XCTAssertFalse(DeviceRevocation.isRevoked(status: 401, body: nil))
        XCTAssertFalse(DeviceRevocation.isRevoked(status: 401, body: Data("device_revoked".utf8)))
        XCTAssertFalse(DeviceRevocation.isRevoked(status: 403, body: json(["error": "device_revoked"])))
    }

    #if os(iOS)
    func testDefaultShieldClearRemovesUnscheduledActivitiesOnIOS() {
        RuleStore.recordUnscheduled(["bedtime.test"])
        defer { RuleStore.recordUnscheduled([]) }
        platformClearShields()
        XCTAssertEqual(RuleStore.unscheduled(), [], "the real iOS clear must run, not a platform-empty closure")
    }
    #endif

    func testARuleSyncAnsweringDeviceRevokedUnpairs() async {
        pairWithRules()
        StubProtocol.response = revoked
        let outcome = await RuleSyncer.syncNow(client: RuleSyncClient(session: StubProtocol.session), enforce: false)
        XCTAssertEqual(outcome, .notPaired)
        assertUnpaired()
    }

    func testAnother401KeepsThePairing() async {
        pairWithRules()
        StubProtocol.response = (401, json(["error": "session_revoked"]))
        let outcome = await RuleSyncer.syncNow(client: RuleSyncClient(session: StubProtocol.session), enforce: false)
        if case .failed = outcome {} else { XCTFail("expected .failed, got \(outcome)") }
        assertStillPaired()
    }

    func testACommandPollAnsweringDeviceRevokedUnpairsAndRunsNothing() async {
        pairWithRules()
        StubProtocol.response = revoked
        var syncs = 0
        let result = await CommandDrainer.drainNow(client: CommandClient(session: StubProtocol.session)) {
            syncs += 1
            return .notPaired
        }
        XCTAssertTrue(result.deviceRevoked)
        XCTAssertEqual(syncs, 0)
        XCTAssertEqual(StubProtocol.requests.count, 1, "the poll only")
        assertUnpaired()
    }

    func testALocationUploadAnsweringDeviceRevokedUnpairs() async {
        pairWithRules()
        StubProtocol.response = revoked
        let outcome = await LocationClient(session: StubProtocol.session)
            .upload(identity, [LocationPing(lat: 1, lng: 2, accuracyM: 5, timestamp: Date())])
        XCTAssertEqual(outcome, .unauthorized)
        assertUnpaired()
    }

    func testATelemetryReportAnsweringDeviceRevokedUnpairs() async {
        pairWithRules()
        StubProtocol.response = revoked
        let status = await LocationClient(session: StubProtocol.session).reportAppliedRulesVersion(identity, 3)
        XCTAssertEqual(status, 401)
        assertUnpaired()
    }

    func testAPushTokenUploadAnsweringDeviceRevokedUnpairs() async {
        pairWithRules()
        StubProtocol.response = revoked
        _ = await PushTokenRegistrar.register(tokenHex: "00abff10", session: StubProtocol.session)
        assertUnpaired()
    }

    /// Every file that sends the device token also handles `device_revoked`, so a new caller cannot forget it.
    func testEveryDeviceTokenCallerHandlesRevocation() throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/FamilyShieldAgent")
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".swift") }
        var callers: [String] = []
        for file in files {
            let text = try String(contentsOf: folder.appendingPathComponent(file), encoding: .utf8)
            guard text.contains("Bearer \\(identity.deviceToken)") else { continue }
            callers.append(file)
            XCTAssertTrue(text.contains("DeviceRevocation."), "\(file) sends the device token but never handles device_revoked")
        }
        XCTAssertGreaterThanOrEqual(callers.count, 4, "rules, commands, location and push: \(callers)")
    }
}
