import XCTest
@testable import OSRAMacAgentFilter

/// The liveness file: the same three properties as the policy snapshot, plus the one that matters here — a
/// corrupt or half-written file must read as nothing, never as "running".
final class FilterLivenessTests: XCTestCase {

    private var directory: URL!
    private var store: FilterLivenessStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("osra-liveness-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = FilterLivenessStore(url: directory.appendingPathComponent("filter-status.json"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // Mutant: writing in place, so a reader can catch a truncated file and decode it as absent — or, worse, as
    // a default struct that says the filter is running.
    func testAWriteIsWholeAndOwnerOnly() throws {
        XCTAssertNil(store.read())
        let written = FilterLiveness(running: true, updatedAt: Date(timeIntervalSince1970: 1_800_000_000))
        try store.write(written)
        XCTAssertEqual(store.read(), written)

        let attributes = try FileManager.default.attributesOfItem(atPath: store.url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    // Mutant: returning a default on a corrupt file, which would read as a running filter.
    func testACorruptFileReadsAsNothing() throws {
        try Data("{\"schemaVersion\":1,\"running\":tr".utf8).write(to: store.url)
        XCTAssertNil(store.read())
    }

    // Mutant: reading a later schema with this build's assumptions.
    func testAnotherSchemaReadsAsNothing() throws {
        try Data("{\"schemaVersion\":99,\"running\":true,\"updatedAt\":\"2026-11-22T00:00:00Z\"}".utf8).write(to: store.url)
        XCTAssertNil(store.read())
    }

    // Mutant: keeping sub-seconds the ISO-8601 file cannot carry, so a value never equals what was written.
    func testAFractionalDateStillRoundTrips() throws {
        let written = FilterLiveness(running: false, updatedAt: Date(timeIntervalSince1970: 1_800_000_000.875))
        try store.write(written)
        XCTAssertEqual(store.read(), written)
    }
}
