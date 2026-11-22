import XCTest
import OSRAMacAgentFilter
@testable import OSRAMacAgentCore

/// The judgement half of the observation. Everything that can be wrong in the mapping is here; the liveness
/// file's own read/write is tested in `OSRAMacAgentFilterTests`.
final class FilterObservationTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func liveness(_ running: Bool, ageSeconds: TimeInterval) -> FilterLiveness {
        FilterLiveness(running: running, updatedAt: now.addingTimeInterval(-ageSeconds))
    }

    // Mutant: treating "no liveness file at all" as `notInstalled`, which tells a parent the filter was never
    // installed when in fact nothing was learned.
    func testNoLivenessFileIsFailedNotNotInstalled() {
        XCTAssertEqual(FilterObservation.provider(liveness: nil, now: now), .failed)
        XCTAssertEqual(FilterObservation.assess(liveness: nil, policyLoaded: true, safeSearchRequested: false, now: now)
            .webFilterState, "unavailable")
    }

    // Mutant: trusting a file of any age, so an extension that crashed an hour ago still reads as running and
    // the parent is told the Mac is filtered.
    func testACrashedExtensionGoesStaleAndStopsCounting() {
        XCTAssertEqual(FilterObservation.provider(liveness: liveness(true, ageSeconds: 0), now: now), .running)
        XCTAssertEqual(FilterObservation.provider(liveness: liveness(true, ageSeconds: 299), now: now), .running)
        XCTAssertEqual(FilterObservation.provider(liveness: liveness(true, ageSeconds: 301), now: now), .stopped)
    }

    // Mutant: ignoring the clean-stop flag, so a filter the parent turned off keeps reporting as running until
    // its file goes stale five minutes later.
    func testACleanStopIsNotARunningFilter() {
        XCTAssertEqual(FilterObservation.provider(liveness: liveness(false, ageSeconds: 0), now: now), .stopped)
    }

    // Mutant: rejecting a file whose clock is ahead, which would flap every time the extension's clock drifts.
    func testAClockAheadIsStillFresh() {
        let ahead = FilterLiveness(running: true, updatedAt: now.addingTimeInterval(30))
        XCTAssertEqual(FilterObservation.provider(liveness: ahead, now: now), .running)
    }

    // Mutant: forgetting one of the two conditions for `ready` — running, and a policy it could read.
    func testReadyNeedsBothARunningProviderAndAPolicy() {
        let fresh = liveness(true, ageSeconds: 1)
        XCTAssertEqual(FilterObservation.assess(liveness: fresh, policyLoaded: true, safeSearchRequested: false, now: now)
            .webFilterState, "ready")
        XCTAssertEqual(FilterObservation.assess(liveness: fresh, policyLoaded: false, safeSearchRequested: false, now: now)
            .webFilterState, "degraded")
        // Codex's SafeSearch decision (#988 `7072593070`): a rule the Mac cannot enforce degrades the report.
        XCTAssertEqual(FilterObservation.assess(liveness: fresh, policyLoaded: true, safeSearchRequested: true, now: now)
            .webFilterState, "degraded")
    }

    // Mutant: letting a stale file plus a policy file promote the report.
    func testAStaleFileWithAPolicyIsStillUnavailable() {
        let stale = liveness(true, ageSeconds: 900)
        XCTAssertEqual(FilterObservation.assess(liveness: stale, policyLoaded: true, safeSearchRequested: false, now: now)
            .webFilterState, "unavailable")
    }
}
