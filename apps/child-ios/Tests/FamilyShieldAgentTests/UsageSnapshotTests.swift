import XCTest
@testable import FamilyShieldAgent

/// #1046: what one day of iOS usage may say. The rows are the rules that keep a report small, ordered and honest —
/// each fails without the behaviour it names.
final class UsageSnapshotTests: XCTestCase {

    private func entry(_ id: String, _ label: String, _ minutes: Int) -> UsageSnapshot.Entry {
        UsageSnapshot.Entry(bundleId: id, label: label, minutes: minutes)
    }

    func testSubMinuteAndUnnamedRowsAreDropped() {
        let snapshot = UsagePolicy.snapshot(day: "2026-11-26", collected: [
            entry("com.google.ios.youtube", "YouTube", 0),
            entry("", "Nameless", 12),
            entry("com.burbn.instagram", "  ", 7),
            entry("com.apple.mobilesafari", "Safari", 4),
        ])
        XCTAssertEqual(snapshot.entries, [entry("com.apple.mobilesafari", "Safari", 4)],
                       "a zero-minute row, a row with no bundle id and a row with no name are all noise")
    }

    func testTheSameAppTwiceIsOneRow() {
        let snapshot = UsagePolicy.snapshot(day: "2026-11-26", collected: [
            entry("com.google.ios.youtube", "YouTube", 6),
            entry("com.google.ios.youtube", "YouTube", 9),
        ])
        XCTAssertEqual(snapshot.entries, [entry("com.google.ios.youtube", "YouTube", 15)],
                       "one app is one row, whatever the report hands over in pieces")
    }

    func testTheListIsLongestFirstAndTiesAreStable() {
        let snapshot = UsagePolicy.snapshot(day: "2026-11-26", collected: [
            entry("b.app", "B", 5), entry("a.app", "A", 5), entry("c.app", "C", 30),
        ])
        XCTAssertEqual(snapshot.entries.map(\.bundleId), ["c.app", "a.app", "b.app"],
                       "most used first, and equal minutes ordered by id so two runs cannot disagree")
    }

    func testTheListIsCapped() {
        let many = (1...30).map { entry("app.\($0)", "App \($0)", $0) }
        let snapshot = UsagePolicy.snapshot(day: "2026-11-26", collected: many)
        XCTAssertEqual(snapshot.entries.count, UsagePolicy.maxEntries)
        XCTAssertEqual(snapshot.entries.first?.bundleId, "app.30", "the cap keeps the most used, not the oldest")
    }

    func testTheSourceIsAlwaysIOS() {
        XCTAssertEqual(UsagePolicy.snapshot(day: "2026-11-26", collected: [entry("a.app", "A", 3)]).source, "ios",
                       "the parent shows iOS usage under its own heading, never in Android's column")
    }

    func testTheDayIsTheChildsDayInItsOwnCalendar() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Dubai")!
        // 2026-11-23 01:30 in Dubai is still 2026-11-22 in UTC: the day must follow the child, not the server.
        let justAfterMidnight = Date(timeIntervalSince1970: 1_795_383_000)
        XCTAssertEqual(UsagePolicy.dayKey(for: justAfterMidnight, calendar: calendar), "2026-11-23")
    }

    func testAnEmptyDayIsNotReportable() {
        let empty = UsagePolicy.snapshot(day: "2026-11-26", collected: [])
        XCTAssertFalse(UsagePolicy.isReportable(empty),
                       "nothing selected or the phone was off is not 'no use' — the parent must not see a zero")
        XCTAssertFalse(UsagePolicy.isReportable(UsageSnapshot(day: "", entries: [entry("a.app", "A", 5)])))
        XCTAssertTrue(UsagePolicy.isReportable(UsagePolicy.snapshot(day: "2026-11-26",
                                                                   collected: [entry("a.app", "A", 5)])))
    }

    func testTheSnapshotRoundTripsThroughTheAppGroupShape() throws {
        let snapshot = UsagePolicy.snapshot(day: "2026-11-26",
                                            collected: [entry("com.google.ios.youtube", "YouTube", 42)])
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(UsageSnapshot.self, from: data)
        XCTAssertEqual(decoded, snapshot, "what the extension writes is what the agent uploads")
    }
}
