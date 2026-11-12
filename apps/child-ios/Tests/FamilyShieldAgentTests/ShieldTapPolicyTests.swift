import XCTest
@testable import FamilyShieldAgent

/// #602 item 1: "Exit to Home screen" no longer alerts the parent on every tap; it is counted instead.
final class ShieldTapPolicyTests: XCTestCase {

    func testRequestAccessAlertsTheParentAndKeepsTheShield() {
        XCTAssertEqual(ShieldTapPolicy.outcome(.requestAccess),
                       .init(alertsParent: true, closesApp: false, countsDismissal: false))
    }

    func testExitHomeClosesTheAppCountsItAndAlertsNobody() {
        XCTAssertEqual(ShieldTapPolicy.outcome(.exitHome),
                       .init(alertsParent: false, closesApp: true, countsDismissal: true))
    }

    func testAnyOtherTapDoesNothing() {
        XCTAssertEqual(ShieldTapPolicy.outcome(.other),
                       .init(alertsParent: false, closesApp: false, countsDismissal: false))
    }

    func testTheDismissalCountGoesUpByOnePerTap() throws {
        let suite = "ShieldTapPolicyTests"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        ShieldTapPolicy.countDismissal(in: defaults)
        ShieldTapPolicy.countDismissal(in: defaults)
        XCTAssertEqual(defaults.integer(forKey: ShieldTapPolicy.dismissalCountKey), 2)
        ShieldTapPolicy.countDismissal(in: nil) // no app group: nothing to count, no crash
        defaults.removePersistentDomain(forName: suite)
    }

    func testTheShieldDelegateSendsNoDismissalAlert() throws {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/FamilyShieldAgent/ShieldConfiguration.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        XCTAssertFalse(text.contains("Shield dismissed by child"), "the dismissal alert is gone")
        XCTAssertTrue(text.contains("ShieldTapPolicy.outcome(tap)"), "the delegate routes through the policy")
        XCTAssertTrue(text.contains("if outcome.alertsParent {"), "only the policy decides who is alerted")
    }
}
