import XCTest
import Darwin
@testable import OSRAMacAgentFilter

/// The three properties the snapshot store promises, each with the fault that would break it. These run as a
/// normal user, so the owner check is exercised through an impossible uid rather than root.
final class PolicySnapshotTests: XCTestCase {

    private var directory: URL!
    private var storeURL: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("osra-policy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        storeURL = directory.appendingPathComponent("filter-policy.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func store(expectedOwner: Int? = nil) -> PolicySnapshotStore {
        PolicySnapshotStore(url: storeURL, expectedOwner: expectedOwner)
    }

    private func snapshot(_ version: Int, rules: Int = 3) -> PolicySnapshot {
        PolicySnapshot(version: version,
                       rulesVersion: rules,
                       policy: FilterPolicy(blockedDomains: ["blocked.example"]))
    }

    // Mutant: returning a partially decoded file (a defaulted struct) instead of nothing, which the extension
    // would then enforce as "everything allowed" while believing it had rules.
    func testAWriteReadsBackWholeAndIsOwnerOnly() throws {
        let store = store()
        XCTAssertNil(store.read(), "an empty directory must read as no policy, not as an empty one")

        try store.write(snapshot(4))
        let read = store.read()
        XCTAssertEqual(read, snapshot(4))
        XCTAssertEqual(read?.policy.decide(host: "www.blocked.example"),
                       .block(reason: "blocked_domain:blocked.example"))

        let attributes = try FileManager.default.attributesOfItem(atPath: storeURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600,
                       "a Standard user must not be able to read or edit the family's block list")
    }

    // Mutant: keeping the sub-second part of `writtenAt`, which the ISO-8601 file cannot carry — a snapshot
    // would then never equal the one read back, and a caller comparing them would see a change on every read.
    func testASnapshotWithAFractionalDateStillRoundTrips() throws {
        let store = store()
        let rolled = PolicySnapshot(version: 2,
                                    rulesVersion: 3,
                                    policy: FilterPolicy(),
                                    writtenAt: Date(timeIntervalSince1970: 1_700_000_000.875))
        try store.write(rolled)
        XCTAssertEqual(store.read(), rolled)
    }

    // Mutant: writing in place, so a crash mid-write leaves a truncated file the provider reads as corrupt.
    func testACrashedWriteLeavesThePreviousVersionReadable() throws {
        let store = store()
        try store.write(snapshot(7))

        // Exactly what a crash between "write the temporary file" and "rename it" leaves behind.
        let temporary = directory.appendingPathComponent("filter-policy.json.tmp")
        try Data("{\"schemaVersion\":1,\"vers".utf8).write(to: temporary)

        XCTAssertEqual(store.read()?.version, 7)

        // The next successful write clears the leftover and lands the new version.
        try store.write(snapshot(8))
        XCTAssertEqual(store.read()?.version, 8)
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.path))
    }

    // Mutant: replacing whatever is at the path, so a file another account planted is adopted as the policy.
    func testAFileWithLoosePermissionsIsNotReplaced() throws {
        try Data("{\"schemaVersion\":1}".utf8).write(to: storeURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: storeURL.path)

        XCTAssertThrowsError(try store().write(snapshot(2))) { error in
            XCTAssertEqual(error as? PolicySnapshotStore.StoreError, .unsafeFileMode(0o644))
        }
        // And the file it refused to touch is still the one that was there.
        XCTAssertEqual(try String(contentsOf: storeURL, encoding: .utf8), "{\"schemaVersion\":1}")
    }

    // Mutant: checking the mode but not the owner, so a 0600 file written by the child's account is adopted.
    func testAFileOwnedByAnotherAccountIsNotReplaced() throws {
        try store().write(snapshot(2))
        let impossibleOwner = 4242
        XCTAssertNotEqual(Int(getuid()), impossibleOwner, "the fixture assumes the runner is not this uid")

        XCTAssertThrowsError(try store(expectedOwner: impossibleOwner).write(snapshot(3))) { error in
            XCTAssertEqual(error as? PolicySnapshotStore.StoreError, .unsafeOwner(Int(getuid())))
        }
        XCTAssertEqual(store().read()?.version, 2)
    }

    // Mutant: accepting any version, so a daemon restarted with stale rules rolls the filter back.
    func testAnOlderSnapshotCannotReplaceANewerOne() throws {
        let store = store()
        try store.write(snapshot(9))

        XCTAssertThrowsError(try store.write(snapshot(8))) { error in
            XCTAssertEqual(error as? PolicySnapshotStore.StoreError, .staleVersion(current: 9, incoming: 8))
        }
        XCTAssertEqual(store.read()?.version, 9, "a refused write must not have touched the file")

        // The same version again is allowed: a re-write after a crash is not a rollback.
        try store.write(snapshot(9))
        XCTAssertEqual(store.read()?.version, 9)
    }

    // Mutant: trusting the file's `schemaVersion`, so a file from a later build is read with this build's
    // assumptions and enforced wrongly.
    func testAFileFromAnotherSchemaIsNotReadAsPolicy() throws {
        let json = """
        {"schemaVersion":99,"version":3,"rulesVersion":3,"writtenAt":"2026-11-22T00:00:00Z",
         "policy":{"pausedInternet":false,"safeSearchEnforced":false,"allowedDomains":[],
                   "blockedDomains":["blocked.example"],"categoryDomains":{}}}
        """
        try Data(json.utf8).write(to: storeURL)
        XCTAssertNil(store().read())
    }

    // Mutant: throwing out of `read()`, which the extension calls on every start; a corrupt file must mean
    // "no policy yet", not a crash loop that leaves the Mac unfiltered and the daemon restarting.
    func testACorruptFileReadsAsNothing() throws {
        try Data("not json at all".utf8).write(to: storeURL)
        XCTAssertNil(store().read())
    }
}
