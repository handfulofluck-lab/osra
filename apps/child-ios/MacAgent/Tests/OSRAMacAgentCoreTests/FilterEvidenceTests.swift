import XCTest
import OSRAMacAgentFilter
@testable import OSRAMacAgentCore

/// Codex's requirement (#989 `7073566839`): prove the capability drops when the evidence goes stale, with a
/// synthetic fixture rather than an unsupported way of killing a process. These tests use the real stores on
/// disk, not a mock, so the path from "a file with an old timestamp" to "the parent is told the filter is not
/// running" is the one that actually runs on a Mac.
final class FilterEvidenceTests: XCTestCase {

    private var directory: URL!
    private var policyStore: PolicySnapshotStore!
    private var livenessStore: FilterLivenessStore!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("osra-evidence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        policyStore = PolicySnapshotStore(url: directory.appendingPathComponent("filter-policy.json"), expectedOwner: nil)
        livenessStore = FilterLivenessStore(url: directory.appendingPathComponent("filter-status.json"))
        try policyStore.write(PolicySnapshot(version: 1,
                                             rulesVersion: 4,
                                             policy: FilterPolicy(blockedDomains: ["blocked.example"]),
                                             writtenAt: now))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // The healthy case, so the fixture below is a change of one variable rather than a different setup.
    func testFreshEvidenceWithAPolicyIsReady() throws {
        try livenessStore.write(FilterLiveness(running: true, updatedAt: now.addingTimeInterval(-30)))
        let status = FilterObservation.current(safeSearchRequested: false,
                                               store: policyStore,
                                               livenessStore: livenessStore,
                                               now: now)
        XCTAssertEqual(status.webFilterState, "ready")
    }

    // The fixture Codex asked for: the extension stopped refreshing, the file is still on disk and still says
    // `running: true`, and the report must stop claiming a filter. This is the failure a killed process leaves.
    func testStaleEvidenceDropsTheCapabilityEvenThoughTheFileSaysRunning() throws {
        try livenessStore.write(FilterLiveness(running: true, updatedAt: now.addingTimeInterval(-6 * 60)))
        let status = FilterObservation.current(safeSearchRequested: false,
                                               store: policyStore,
                                               livenessStore: livenessStore,
                                               now: now)
        XCTAssertEqual(status.webFilterState, "unavailable")
        // And nothing else was allowed to promote it: the policy file is still there and still valid.
        XCTAssertNotNil(policyStore.read())
    }

    // The same fixture one tick inside the window: the boundary must be where the code says it is, not where a
    // flaky run happens to fall.
    func testTheBoundaryIsTheWindowItself() throws {
        try livenessStore.write(FilterLiveness(running: true, updatedAt: now.addingTimeInterval(-300)))
        XCTAssertEqual(FilterObservation.current(safeSearchRequested: false, store: policyStore,
                                                 livenessStore: livenessStore, now: now).webFilterState, "ready")
        try livenessStore.write(FilterLiveness(running: true, updatedAt: now.addingTimeInterval(-301)))
        XCTAssertEqual(FilterObservation.current(safeSearchRequested: false, store: policyStore,
                                                 livenessStore: livenessStore, now: now).webFilterState, "unavailable")
    }

    // A clean stop writes its own word, and it must not need the window to expire to be believed.
    func testACleanStopIsBelievedImmediately() throws {
        try livenessStore.write(FilterLiveness(running: false, updatedAt: now))
        XCTAssertEqual(FilterObservation.current(safeSearchRequested: false, store: policyStore,
                                                 livenessStore: livenessStore, now: now).webFilterState, "unavailable")
    }

    // Running, fresh, with the family asking for SafeSearch: the Mac cannot enforce it, so `degraded`.
    func testAPolicyAskingForSafeSearchDegradesTheReport() throws {
        try livenessStore.write(FilterLiveness(running: true, updatedAt: now))
        XCTAssertEqual(FilterObservation.current(safeSearchRequested: true, store: policyStore,
                                                 livenessStore: livenessStore, now: now).webFilterState, "degraded")
    }
}
