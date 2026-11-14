import Foundation
import XCTest
@testable import FamilyShieldAgent

final class RingPolicyTests: XCTestCase {
    private let id = UUID(uuidString: "6F1C2B8E-3D4A-4E5F-9A0B-1C2D3E4F5A6B")!

    private func state(endAt: Date = Date(timeIntervalSince1970: 300), monotonicStart: TimeInterval = 0) -> RingState {
        RingState(commandId: id, startedAt: Date(timeIntervalSince1970: 0), endAt: endAt,
                  monotonicStart: monotonicStart, stopSource: nil, dismissalCount: 0)
    }

    func testOnlyPINParentAndTimeoutAreStops() {
        XCTAssertEqual(RingPolicy.event(for: .pinVerified), .pinStopped)
        XCTAssertEqual(RingPolicy.event(for: .parentCommand), .parentStopped)
        XCTAssertEqual(RingPolicy.event(for: .timeout), .timedOut)
        XCTAssertNil(RingPolicy.event(for: .childDismissed))
    }

    func testWallJumpDoesNotEndRingEarly() {
        XCTAssertFalse(RingPolicy.hasTimedOut(state(), nowWall: Date(timeIntervalSince1970: 600),
                                              nowMonotonic: 30, restarted: false))
    }

    func testTimeoutRequiresBothClocks() {
        XCTAssertTrue(RingPolicy.hasTimedOut(state(), nowWall: Date(timeIntervalSince1970: 300),
                                             nowMonotonic: 300, restarted: false))
        XCTAssertFalse(RingPolicy.hasTimedOut(state(), nowWall: Date(timeIntervalSince1970: 300),
                                              nowMonotonic: 299.9, restarted: false))
        XCTAssertFalse(RingPolicy.hasTimedOut(state(), nowWall: Date(timeIntervalSince1970: 299),
                                              nowMonotonic: 300, restarted: false))
    }

    func testRestartUsesStoredWallClockEnd() {
        XCTAssertTrue(RingPolicy.hasTimedOut(state(), nowWall: Date(timeIntervalSince1970: 300),
                                             nowMonotonic: 0, restarted: true))
        XCTAssertFalse(RingPolicy.hasTimedOut(state(), nowWall: Date(timeIntervalSince1970: 299),
                                              nowMonotonic: 600, restarted: true))
    }

    func testCapIsFiveMinutes() {
        XCTAssertEqual(RingPolicy.duration, 300)
    }

    func testStateRoundTripPreservesStopAndDismissalCount() throws {
        var original = state(monotonicStart: 42)
        original.stopSource = .pinVerified
        original.dismissalCount = 3
        let restored = try JSONDecoder().decode(RingState.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(restored, original)
        XCTAssertEqual(restored.stopSource, .pinVerified)
        XCTAssertEqual(restored.dismissalCount, 3)
    }

    func testEveryDismissalHasItsOwnDedupeKey() {
        let first = RingPolicy.dedupeKey(for: .childDismissed, ringId: id, dismissalCount: 1)
        let second = RingPolicy.dedupeKey(for: .childDismissed, ringId: id, dismissalCount: 2)
        XCTAssertEqual(first, "ring:\(id):child_dismissed:1")
        XCTAssertEqual(second, "ring:\(id):child_dismissed:2")
        XCTAssertNotEqual(first, second)
    }

    func testEachStopHasOneDedupeKey() {
        XCTAssertEqual(RingPolicy.dedupeKey(for: .pinStopped, ringId: id, dismissalCount: 2),
                       "ring:\(id):pin_stopped")
        XCTAssertEqual(RingPolicy.dedupeKey(for: .parentStopped, ringId: id, dismissalCount: 0),
                       "ring:\(id):parent_stopped")
        XCTAssertEqual(RingPolicy.dedupeKey(for: .timedOut, ringId: id, dismissalCount: 0),
                       "ring:\(id):timed_out")
    }
}
