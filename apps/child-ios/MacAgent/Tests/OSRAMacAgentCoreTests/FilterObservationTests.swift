import XCTest
import OSRAMacAgentFilter
@testable import OSRAMacAgentCore

/// The judgement half of the observation. The question half (`NEFilterManager.status`) has no answer on a
/// runner, so it is the signed device row's; everything that can be wrong in the mapping is here.
final class FilterObservationTests: XCTestCase {

    // Mutant: treating "the system did not answer" as `notInstalled`, which tells a parent the filter was never
    // installed when in fact nothing was learned.
    func testAnUnansweredQuestionIsFailedNotNotInstalled() {
        let status = FilterObservation.assess(observed: nil, policyLoaded: true, safeSearchRequested: false)
        XCTAssertEqual(status.provider, .failed)
        XCTAssertEqual(status.webFilterState, "unavailable")
    }

    // Mutant: reporting `ready` from a policy file alone, without the system saying the provider runs.
    func testAPolicyOnDiskIsNotAFilterThatRuns() {
        XCTAssertEqual(FilterObservation.assess(observed: .stopped, policyLoaded: true, safeSearchRequested: false).webFilterState,
                       "unavailable")
        XCTAssertEqual(FilterObservation.assess(observed: .notInstalled, policyLoaded: true, safeSearchRequested: false).webFilterState,
                       "unavailable")
        XCTAssertEqual(FilterObservation.assess(observed: .failed, policyLoaded: true, safeSearchRequested: false).webFilterState,
                       "unavailable")
    }

    // Mutant: forgetting one of the two conditions for `ready` — running, and a policy it could read.
    func testReadyNeedsBothARunningProviderAndAPolicy() {
        XCTAssertEqual(FilterObservation.assess(observed: .running, policyLoaded: true, safeSearchRequested: false).webFilterState,
                       "ready")
        XCTAssertEqual(FilterObservation.assess(observed: .running, policyLoaded: false, safeSearchRequested: false).webFilterState,
                       "degraded")
        XCTAssertEqual(FilterObservation.assess(observed: .running, policyLoaded: true, safeSearchRequested: true).webFilterState,
                       "degraded")
    }

    // Mutant: dropping the SafeSearch flag on the way through, which would report a working filter that cannot
    // enforce one of the family's rules as fully ready.
    func testTheSafeSearchFlagSurvivesTheObservation() {
        let status = FilterObservation.assess(observed: .running, policyLoaded: true, safeSearchRequested: true)
        XCTAssertTrue(status.safeSearchRequested)
        XCTAssertEqual(status.pauseInternetState, "unavailable")
    }
}
