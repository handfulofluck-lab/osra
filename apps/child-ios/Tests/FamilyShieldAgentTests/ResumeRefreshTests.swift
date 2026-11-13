import XCTest
@testable import FamilyShieldAgent

/// #690: a phone the parent removed leaves the paired state when the app comes back to the front, not only on a
/// cold launch.
final class ResumeRefreshTests: XCTestCase {
    func testAResumeRefreshesUnlessOneJustRan() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(ResumeRefresh.isDue(last: .distantPast, now: now), "first resume")
        XCTAssertFalse(ResumeRefresh.isDue(last: now.addingTimeInterval(-5), now: now), "right after a launch")
        XCTAssertTrue(ResumeRefresh.isDue(last: now.addingTimeInterval(-ResumeRefresh.minInterval), now: now))
        XCTAssertTrue(ResumeRefresh.isDue(last: now.addingTimeInterval(-3600), now: now), "back after an hour")
    }

    func testTheResumeHookRunsTheRevocationCheck() throws {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/FamilyShieldAgent/PairingView.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        let hook = try XCTUnwrap(text.range(of: "UIApplication.didBecomeActiveNotification"))
        let call = try XCTUnwrap(text.range(of: "Task { await refreshAfterResume() }"))
        XCTAssertGreaterThan(call.lowerBound, hook.lowerBound, "the resume handler starts the refresh")
        let body = try XCTUnwrap(text.range(of: "private func refreshAfterResume() async {"))
        let rest = String(text[body.upperBound...].prefix(400))
        XCTAssertTrue(rest.contains("await syncNow()"), "the refresh drains and syncs, so device_revoked unpairs")
        let syncNow = try XCTUnwrap(text.range(of: "private func syncNow() async {"))
        XCTAssertTrue(String(text[syncNow.upperBound...].prefix(900)).contains("leaveIfUnpaired()"),
                      "and then shows pairing")
    }
}
