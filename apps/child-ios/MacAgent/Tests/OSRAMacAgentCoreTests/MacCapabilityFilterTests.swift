import XCTest
import FamilyShieldAgent
import OSRAMacAgentFilter
@testable import OSRAMacAgentCore

/// Step (iii), #988: the report is where an over-promise would reach the parent, so the one feature that can
/// now move must move only on evidence, and the ones that cannot must stay where they are.
final class MacCapabilityFilterTests: XCTestCase {

    private func features(_ report: MacCapabilityReport) throws -> [String: String] {
        try XCTUnwrap(report.json["features"] as? [String: String])
    }

    // Mutant: defaulting to a running provider, so a daemon built without the extension claims a working
    // filter on every heartbeat.
    func testABuildWithNoExtensionStillReportsWebFilterUnavailable() throws {
        let features = try features(MacCapabilityReport())
        XCTAssertEqual(features["web_filter"], "unavailable")
        XCTAssertEqual(Set(features.values), ["unavailable"], "nothing else may start claiming yet")
    }

    // Mutant: mapping `degraded` to `ready`, or sending a word outside the server's vocabulary.
    func testTheFilterStatesAreTheServersVocabulary() throws {
        let ready = try features(MacCapabilityReport(filterStatus: FilterStatus(provider: .running, policyLoaded: true)))
        XCTAssertEqual(ready["web_filter"], "ready")

        let degraded = try features(MacCapabilityReport(filterStatus: FilterStatus(provider: .running, policyLoaded: false)))
        XCTAssertEqual(degraded["web_filter"], "degraded")

        for provider in [FilterStatus.Provider.stopped, .failed, .notInstalled] {
            let stopped = try features(MacCapabilityReport(filterStatus: FilterStatus(provider: provider, policyLoaded: true)))
            XCTAssertEqual(stopped["web_filter"], "unavailable", "\(provider)")
        }

        // FEATURE_STATES in packages/shared-types: the server rejects anything else.
        let allowed: Set<String> = ["ready", "degraded", "unavailable", "not_supported"]
        for provider in [FilterStatus.Provider.stopped, .failed, .notInstalled, .running] {
            for loaded in [true, false] {
                let values = try features(MacCapabilityReport(filterStatus: FilterStatus(provider: provider, policyLoaded: loaded)))
                XCTAssertTrue(Set(values.values).isSubset(of: allowed), "\(provider) \(loaded)")
            }
        }
    }

    // Mutant: letting pause ride along with the filter, which would tell a parent they can pause the Mac's
    // internet before that path exists.
    func testPauseInternetNeverRidesAlongWithTheFilter() throws {
        let features = try features(MacCapabilityReport(filterStatus: FilterStatus(provider: .running, policyLoaded: true)))
        XCTAssertEqual(features["pause_internet"], "unavailable")
        XCTAssertEqual(features["app_blocking"], "unavailable")
        XCTAssertEqual(features["screen_time"], "unavailable")
    }
}
