import XCTest
@testable import OSRAMacAgentCore

/// #990's eight contract cases, one per rule. Each names the fault it prevents; none of them needs a signed Mac.
final class PauseSequencerTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // 1. Mutant: acking on receipt. A parent would read "paused" while the child is browsing.
    func testAPauseIsAcceptedButNotAppliedUntilConfirmed() {
        let accepted = PauseSequencer.accept(.paused, current: nil, filterRunning: true, now: now)
        XCTAssertEqual(accepted.outcome, .pending(op: 1))
        XCTAssertEqual(accepted.state.op, 1)
        XCTAssertFalse(accepted.state.isApplied)

        let confirmed = PauseSequencer.confirm(op: 1, version: 7, current: accepted.state)
        XCTAssertEqual(confirmed.outcome, .applied(op: 1, version: 7))
        XCTAssertTrue(confirmed.state.isApplied)
        XCTAssertEqual(confirmed.state.desired, .paused)
    }

    // 2. Mutant: marking an operation applied when the confirmation source is not running, which is a claim
    // about a filter nobody observed.
    func testAProviderThatIsDownLeavesTheOperationPending() {
        let accepted = PauseSequencer.accept(.paused, current: nil, filterRunning: false, now: now)
        XCTAssertEqual(accepted.outcome, .pending(op: 1))
        XCTAssertFalse(accepted.state.isApplied)
        // And it stays pending across restarts until something confirms it.
        XCTAssertEqual(PauseSequencer.reconciliation(accepted.state), .paused)
        XCTAssertFalse(accepted.state.isApplied)
    }

    // 3. Mutant: refusing a resume while the filter is down, which leaves the Mac paused with no way back.
    func testAResumeWithTheProviderDownIsAcceptedAndAppliesOnRestart() {
        let paused = PauseSequencer.confirm(op: 1, version: 3,
                                            current: PauseSequencer.accept(.paused, current: nil, filterRunning: true, now: now).state).state
        let resumed = PauseSequencer.accept(.unpaused, current: paused, filterRunning: false, now: now)
        XCTAssertEqual(resumed.outcome, .pending(op: 2), "a resume is taken even with no filter to apply it")
        XCTAssertEqual(PauseSequencer.reconciliation(resumed.state), .unpaused)
    }

    // 4. Mutant: applying a late pause confirmation after a newer resume — the Mac pauses after the parent
    // turned it back on.
    func testALatePauseConfirmationAfterANewerResumeIsDiscarded() {
        let pause = PauseSequencer.accept(.paused, current: nil, filterRunning: true, now: now)
        let resume = PauseSequencer.accept(.unpaused, current: pause.state, filterRunning: true, now: now)

        let late = PauseSequencer.confirm(op: 1, version: 4, current: resume.state)
        XCTAssertEqual(late.outcome, .stale(op: 1, supersededBy: 2))
        XCTAssertEqual(late.state, resume.state, "a stale confirmation must not move the state")
        XCTAssertEqual(late.state.desired, .unpaused)

        let fresh = PauseSequencer.confirm(op: 2, version: 5, current: resume.state)
        XCTAssertEqual(fresh.outcome, .applied(op: 2, version: 5))
    }

    // 5. Mutant: recording a confirmation the daemon never published, i.e. an applied state that no policy
    // version backs.
    func testAConfirmationForAnOperationNeverAcceptedIsNotApplied() {
        let state = PauseState(op: 0, appliedOp: 0, desired: .unpaused, updatedAt: now)
        let ahead = PauseSequencer.confirm(op: 9, version: 1, current: state)
        XCTAssertEqual(ahead.outcome, .pending(op: 0), "an operation the daemon never assigned cannot be applied")
        XCTAssertEqual(ahead.state, state)
    }

    // 6. Mutant: losing the parent's request across a restart, so a paused Mac comes back online.
    func testRestartWithDesiredPausedAppliesPaused() {
        let paused = PauseSequencer.confirm(op: 1, version: 2,
                                            current: PauseSequencer.accept(.paused, current: nil, filterRunning: true, now: now).state)
        XCTAssertEqual(PauseSequencer.reconciliation(paused.state), .paused)
        XCTAssertTrue(paused.state.isApplied)
    }

    // 7. Mutant: a crash that froze a paused state leaving the child offline permanently — the unpaused case must
    // reconcile first, whatever else the daemon does at start.
    func testRestartWithDesiredUnpausedPublishesUnpausedFirst() {
        let resumed = PauseSequencer.accept(.unpaused, current: nil, filterRunning: false, now: now)
        XCTAssertEqual(PauseSequencer.reconciliation(resumed.state), .unpaused)
        // No state at all is the same answer, so a first run and a lost file both come up online.
        XCTAssertEqual(PauseSequencer.reconciliation(nil), .unpaused)
    }

    // 8. Mutant: promoting a command ack into a capability claim, telling the parent pause works before the
    // signed rows have proven it.
    func testTheCapabilityStaysUnavailableWhateverTheCommandsSay() {
        XCTAssertEqual(PauseSequencer.capabilityState(), "unavailable")
        let applied = PauseSequencer.confirm(op: 1, version: 1,
                                             current: PauseSequencer.accept(.paused, current: nil, filterRunning: true, now: now).state)
        XCTAssertEqual(applied.outcome, .applied(op: 1, version: 1))
        XCTAssertEqual(PauseSequencer.capabilityState(), "unavailable", "an applied command is not a shipped capability")
    }
}
