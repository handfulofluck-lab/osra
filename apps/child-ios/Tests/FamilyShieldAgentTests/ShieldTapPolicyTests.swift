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
        // #744 adds the throttle as a second condition; the policy's outcome still comes first and decides who is alerted.
        XCTAssertTrue(text.contains("if outcome.alertsParent,\n           ShieldTapPolicy.shouldSendRequest("),
                      "only the policy decides who is alerted, then the throttle")
    }

    // MARK: - #744: Request access is throttled per target

    private func freshDefaults() -> UserDefaults {
        let name = "ShieldTapPolicyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    func testASecondRequestForTheSameAppInsideTheWindowSendsNothing() {
        let defaults = freshDefaults()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(ShieldTapPolicy.shouldSendRequest(target: "app:A", now: start, defaults: defaults))
        for second in [1.0, 5, 60, 299] {
            XCTAssertFalse(ShieldTapPolicy.shouldSendRequest(target: "app:A", now: start + second, defaults: defaults),
                           "tap at +\(second)s")
        }
        XCTAssertTrue(ShieldTapPolicy.shouldSendRequest(target: "app:A", now: start + ShieldTapPolicy.requestWindow,
                                                        defaults: defaults), "a new request once the window has passed")
    }

    func testAnotherAppIsItsOwnRequest() {
        let defaults = freshDefaults()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(ShieldTapPolicy.shouldSendRequest(target: "app:A", now: now, defaults: defaults))
        XCTAssertTrue(ShieldTapPolicy.shouldSendRequest(target: "app:B", now: now, defaults: defaults))
        XCTAssertTrue(ShieldTapPolicy.shouldSendRequest(target: "web:A", now: now, defaults: defaults))
    }

    func testTenQuickTapsSendOneRequest() {
        let defaults = freshDefaults()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let sent = (0..<10).filter {
            ShieldTapPolicy.shouldSendRequest(target: "app:A", now: start + Double($0) * 1.7, defaults: defaults)
        }
        XCTAssertEqual(sent.count, 1, "the child-escape run's 10 taps in 17 s")
    }

    func testWithNoAppGroupTheRequestIsStillSent() {
        XCTAssertTrue(ShieldTapPolicy.shouldSendRequest(target: "app:A", defaults: nil))
        XCTAssertTrue(ShieldTapPolicy.shouldSendRequest(target: "app:A", defaults: nil), "never lost to storage")
    }

    func testTheShieldDelegateGatesTheAlertOnTheThrottle() throws {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/FamilyShieldAgent/ShieldConfiguration.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        let gate = try XCTUnwrap(text.range(of: "ShieldTapPolicy.shouldSendRequest(target: target"))
        let report = try XCTUnwrap(text.range(of: "reporter.report(\n                category: \"app_blocked\""))
        XCTAssertLessThan(gate.lowerBound, report.lowerBound, "the alert is sent only past the throttle")
        XCTAssertEqual(text.components(separatedBy: "respond(to: action, target: Self.target(").count - 1, 3,
                       "apps, websites and categories each pass their own target")
    }
}
