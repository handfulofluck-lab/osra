import XCTest
import FamilyShieldAgent
@testable import OSRAMacAgentCore
import OSRAMacAgentFilter

/// What the daemon publishes, and what it refuses to publish. Each test names its mutant.
final class MacPolicyPublisherTests: XCTestCase {

    private var directory: URL!
    private var store: PolicySnapshotStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("osra-publish-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = PolicySnapshotStore(url: directory.appendingPathComponent("filter-policy.json"), expectedOwner: nil)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func rules(blocked: [String] = ["blocked.example"],
                       allowed: [String] = ["school.example"],
                       safeSearch: Bool = true,
                       version: Int = 3) throws -> RuleSet {
        let allowedJSON = try encode(allowed)
        let blockedJSON = try encode(blocked)
        let json = """
        {
          "rulesVersion": \(version),
          "screenTime": {"dailyLimitMinutes": 0, "weekendLimitMinutes": 0, "bedtimeStart": "21:00",
                         "bedtimeEnd": "07:00", "schoolHours": {"start": "08:00", "end": "15:00", "days": []}},
          "webFilter": {"blockedCategories": ["games"], "allowedDomains": \(allowedJSON),
                        "blockedDomains": \(blockedJSON), "safeSearchEnforced": \(safeSearch)},
          "appRules": [], "routines": [], "alwaysAllowedApps": []
        }
        """
        return try JSONDecoder().decode(RuleSet.self, from: Data(json.utf8))
    }

    private func encode(_ values: [String]) throws -> String {
        String(decoding: try JSONEncoder().encode(values), as: UTF8.self)
    }

    // Mutant: writing on every sync, so the file the extension reads is replaced every fifteen minutes whether
    // the rules changed or not.
    func testTheFirstSyncWritesAndAnIdenticalSecondSyncDoesNot() throws {
        let first = try MacPolicyPublisher.publish(try rules(), store: store)
        XCTAssertEqual(first, MacPolicyPublisher.Published(version: 1, changed: true))
        let written = try XCTUnwrap(store.read())
        XCTAssertEqual(written.version, 1)
        XCTAssertEqual(written.rulesVersion, 3)

        let attributes = try FileManager.default.attributesOfItem(atPath: store.url.path)
        let stamp = attributes[.modificationDate] as? Date

        let second = try MacPolicyPublisher.publish(try rules(), store: store)
        XCTAssertEqual(second, MacPolicyPublisher.Published(version: 1, changed: false))
        let after = try FileManager.default.attributesOfItem(atPath: store.url.path)
        XCTAssertEqual(after[.modificationDate] as? Date, stamp, "an unchanged sync must not touch the file")
    }

    // Mutant: numbering from a fresh counter each launch, so the version goes backwards and the extension —
    // which ignores a lower version — stops seeing new rules.
    func testTheVersionRisesFromWhatIsOnDiskNotFromMemory() throws {
        _ = try MacPolicyPublisher.publish(try rules(blocked: ["a.example"]), store: store)
        let second = try MacPolicyPublisher.publish(try rules(blocked: ["b.example"]), store: store)
        XCTAssertEqual(second, MacPolicyPublisher.Published(version: 2, changed: true))

        // A restart: a new publisher instance, the same file. The counter continues.
        let restarted = PolicySnapshotStore(url: store.url, expectedOwner: nil)
        let third = try MacPolicyPublisher.publish(try rules(blocked: ["c.example"]), store: restarted)
        XCTAssertEqual(third, MacPolicyPublisher.Published(version: 3, changed: true))
        XCTAssertEqual(restarted.read()?.policy.blockedDomains, ["c.example"])
    }

    // Mutant: copying `safeSearchEnforced` (or the lists) the wrong way round, so the Mac filters a rule the
    // parent never set.
    func testThePublishedPolicyIsTheRulesWebFilter() throws {
        _ = try MacPolicyPublisher.publish(try rules(blocked: ["blocked.example", "Other.Example."],
                                                    allowed: ["school.example"],
                                                    safeSearch: true),
                                           store: store)
        let policy = try XCTUnwrap(store.read()?.policy)
        XCTAssertEqual(policy.blockedDomains, ["blocked.example", "other.example"])
        XCTAssertEqual(policy.allowedDomains, ["school.example"])
        XCTAssertTrue(policy.safeSearchEnforced)
        XCTAssertEqual(policy.decide(host: "www.blocked.example"), .block(reason: "blocked_domain:blocked.example"))
        XCTAssertEqual(policy.decide(host: "school.example"), .allow)
    }

    // Mutant: publishing `pausedInternet` from the rule set. Pause is a command with a lifetime; a stale sync
    // would leave the Mac offline after the parent resumed it.
    func testPauseIsNeverPublishedFromTheRules() throws {
        _ = try MacPolicyPublisher.publish(try rules(), store: store)
        XCTAssertEqual(store.read()?.policy.pausedInternet, false)
    }

    // Mutant: leaving the last policy on disk when consent is withdrawn, so the Mac keeps sinking domains after
    // the family revoked it. The Android syncer clears its rules on this outcome; the Mac must stop enforcing.
    func testConsentWithdrawalClearsThePolicy() throws {
        _ = try MacPolicyPublisher.publish(try rules(blocked: ["blocked.example"]), store: store)
        XCTAssertEqual(store.read()?.policy.decide(host: "blocked.example"),
                       .block(reason: "blocked_domain:blocked.example"))

        let cleared = try MacPolicyPublisher.clear(store: store)
        XCTAssertEqual(cleared, MacPolicyPublisher.Published(version: 2, changed: true))
        XCTAssertEqual(store.read()?.policy, FilterPolicy())
        XCTAssertEqual(store.read()?.policy.decide(host: "blocked.example"), .allow)
        XCTAssertEqual(store.read()?.rulesVersion, 0)

        // Clearing twice is not a new policy, and the version must not churn on every sync after withdrawal.
        XCTAssertEqual(try MacPolicyPublisher.clear(store: store),
                       MacPolicyPublisher.Published(version: 2, changed: false))
    }

    // Mutant: clearing by deleting the file, which resets the version to 1 on the next publish and makes the
    // extension ignore a re-pairing until the counter catches up.
    func testAFreshPairingAfterWithdrawalContinuesTheVersion() throws {
        _ = try MacPolicyPublisher.publish(try rules(), store: store)
        _ = try MacPolicyPublisher.clear(store: store)
        let republished = try MacPolicyPublisher.publish(try rules(blocked: ["again.example"]), store: store)
        XCTAssertEqual(republished, MacPolicyPublisher.Published(version: 3, changed: true))
        XCTAssertEqual(store.read()?.policy.blockedDomains, ["again.example"])
    }

    // Mutant: swallowing a store refusal and reporting success, so the daemon logs a publish that never
    // happened while the extension keeps enforcing yesterday's rules.
    func testARefusedWriteIsThrownNotSwallowed() throws {
        try Data("{\"schemaVersion\":1}".utf8).write(to: store.url)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: store.url.path)

        XCTAssertThrowsError(try MacPolicyPublisher.publish(try rules(), store: store)) { error in
            XCTAssertEqual(error as? PolicySnapshotStore.StoreError, .unsafeFileMode(0o644))
        }
    }
}
