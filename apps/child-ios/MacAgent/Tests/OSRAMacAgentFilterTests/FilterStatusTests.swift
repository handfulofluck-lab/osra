import XCTest
@testable import OSRAMacAgentFilter

/// The one rule about reporting: a feature says it works only when it is working.
final class FilterStatusTests: XCTestCase {

    // Mutant: reporting `ready` from the build's ability rather than from a running provider, which tells a
    // parent the Mac is filtered while it is not — the exact over-promise ADR-0034 exists to prevent.
    func testOnlyARunningProviderWithAPolicyIsReady() {
        XCTAssertEqual(FilterStatus(provider: .running, policyLoaded: true).webFilterState, "ready")
        XCTAssertEqual(FilterStatus(provider: .running, policyLoaded: false).webFilterState, "degraded")
        XCTAssertEqual(FilterStatus(provider: .stopped, policyLoaded: true).webFilterState, "unavailable")
        XCTAssertEqual(FilterStatus(provider: .failed, policyLoaded: true).webFilterState, "unavailable")
        XCTAssertEqual(FilterStatus(provider: .notInstalled, policyLoaded: false).webFilterState, "unavailable")
    }

    // Mutant: claiming pause from the decision table. Pause on the Mac is a separate path that this step does
    // not build, so it stays unavailable however the filter is doing.
    func testPauseStaysUnavailableWhateverTheFilterDoes() {
        for provider in [FilterStatus.Provider.notInstalled, .stopped, .running, .failed] {
            XCTAssertEqual(FilterStatus(provider: provider, policyLoaded: true).pauseInternetState, "unavailable")
        }
    }
}
