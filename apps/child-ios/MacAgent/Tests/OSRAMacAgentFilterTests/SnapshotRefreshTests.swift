import XCTest
@testable import OSRAMacAgentFilter

/// The gate in front of the per-flow read. Each test names the fault it prevents.
final class SnapshotRefreshTests: XCTestCase {

    private let first = Date(timeIntervalSince1970: 1_800_000_000)
    private lazy var later = first.addingTimeInterval(60)

    // Mutant: reading on every flow. The filter would decode JSON thousands of times in the data path.
    func testTheSameModificationDateDoesNotAskForAnotherRead() {
        var refresh = SnapshotRefresh()
        XCTAssertTrue(refresh.shouldReload(fileModification: first), "the first look always reads")
        XCTAssertFalse(refresh.shouldReload(fileModification: first))
        XCTAssertFalse(refresh.shouldReload(fileModification: first))
    }

    // Mutant: caching the date but never comparing, so a rule change would never reach the filter.
    func testAMovedDateAsksForOneRead() {
        var refresh = SnapshotRefresh()
        _ = refresh.shouldReload(fileModification: first)
        XCTAssertTrue(refresh.shouldReload(fileModification: later))
        XCTAssertFalse(refresh.shouldReload(fileModification: later))
    }

    // Mutant: treating "no file" and "a file" as the same, so the policy that appears after pairing is ignored.
    func testAFileAppearingIsAChange() {
        var refresh = SnapshotRefresh()
        XCTAssertFalse(refresh.shouldReload(fileModification: nil), "nothing to read yet, and nothing cached to lose")
        XCTAssertTrue(refresh.shouldReload(fileModification: first))
    }

    // Mutant: forgetting a deletion, so a removed policy keeps being enforced from memory forever.
    func testAFileDisappearingIsAChange() {
        var refresh = SnapshotRefresh()
        _ = refresh.shouldReload(fileModification: first)
        XCTAssertTrue(refresh.shouldReload(fileModification: nil))
    }

    // Mutant: recording the version before the read succeeds, so a corrupt file leaves the cache claiming a
    // version it never loaded.
    func testOnlyAReadSnapshotMovesTheAppliedVersion() {
        var refresh = SnapshotRefresh()
        XCTAssertEqual(refresh.appliedVersion, -1)
        refresh.applied(PolicySnapshot(version: 4, rulesVersion: 2, policy: FilterPolicy()))
        XCTAssertEqual(refresh.appliedVersion, 4)
        refresh.applied(nil)
        XCTAssertEqual(refresh.appliedVersion, -1)
    }
}
