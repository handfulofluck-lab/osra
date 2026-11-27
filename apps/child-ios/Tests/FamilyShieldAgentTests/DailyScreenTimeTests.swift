import Foundation
import XCTest
@testable import FamilyShieldAgent

final class DailyScreenTimeTests: XCTestCase {
    private var calendar: Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = TimeZone(secondsFromGMT: 4 * 60 * 60)!
        return result
    }

    private func date(_ day: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour))!
    }

    func testBonusRaisesCumulativeThresholdOnlyOnItsDay() {
        let friday = date(27)
        let saturday = date(28)
        let limits = DailyScreenTimeLimits(weekdayMinutes: 5, weekendMinutes: 30)
        var bonuses = DailyScreenTimeBonuses()

        XCTAssertEqual(limits.threshold(at: friday, calendar: calendar, bonuses: bonuses)?.minutes, 5)
        XCTAssertTrue(bonuses.record(
            DailyScreenTimeGrant(id: "grant", minutes: 15, issuedAt: friday),
            at: friday, calendar: calendar
        ))
        let effective = limits.threshold(at: friday, calendar: calendar, bonuses: bonuses)
        XCTAssertEqual(effective?.minutes, 20)
        XCTAssertEqual(limits.events(at: friday, calendar: calendar, bonuses: bonuses).map(\.minutes), [5, 30, 20])
        XCTAssertEqual(limits.threshold(at: saturday, calendar: calendar, bonuses: bonuses)?.minutes, 30)
    }

    func testRedeliveryDoesNotAddASecondGrantAndYesterdayCannotBeRecorded() {
        let issued = date(27, hour: 23)
        let grant = DailyScreenTimeGrant(id: "grant", minutes: 15, issuedAt: issued)
        var bonuses = DailyScreenTimeBonuses()
        XCTAssertTrue(bonuses.record(grant, at: issued, calendar: calendar))
        XCTAssertTrue(bonuses.record(grant, at: issued, calendar: calendar))
        XCTAssertEqual(bonuses.minutes(at: issued, calendar: calendar), 15)

        let nextDay = date(28, hour: 0)
        XCTAssertFalse(bonuses.record(grant, at: nextDay, calendar: calendar))
        XCTAssertEqual(bonuses.minutes(at: nextDay, calendar: calendar), 0)
    }

    func testBonusCannotCreateACapOnAnUnlimitedDay() {
        let friday = date(27)
        var bonuses = DailyScreenTimeBonuses()
        XCTAssertTrue(bonuses.record(
            DailyScreenTimeGrant(id: "grant", minutes: 15, issuedAt: friday),
            at: friday, calendar: calendar
        ))
        let limits = DailyScreenTimeLimits(weekdayMinutes: 0, weekendMinutes: 30)
        XCTAssertNil(limits.threshold(at: friday, calendar: calendar, bonuses: bonuses))
        XCTAssertNil(limits.threshold(at: date(28), calendar: calendar, bonuses: bonuses))
        XCTAssertTrue(limits.events(at: friday, calendar: calendar, bonuses: bonuses).isEmpty)
    }

    func testAbsentWeekendOverrideKeepsWeekdayLimit() {
        let limits = DailyScreenTimeLimits(weekdayMinutes: 40, weekendMinutes: 0)
        XCTAssertEqual(limits.threshold(at: date(28), calendar: calendar,
                                        bonuses: DailyScreenTimeBonuses())?.minutes, 40)
    }

    func testMaximumValueCannotOverflowDailyMinutes() {
        let friday = date(27)
        var bonuses = DailyScreenTimeBonuses()
        XCTAssertTrue(bonuses.record(
            DailyScreenTimeGrant(id: "large", minutes: Int.max, issuedAt: friday),
            at: friday, calendar: calendar
        ))
        let limits = DailyScreenTimeLimits(weekdayMinutes: 5, weekendMinutes: 30)
        XCTAssertEqual(
            limits.threshold(at: friday, calendar: calendar, bonuses: bonuses)?.minutes,
            DailyScreenTimeLimits.maximumMinutes
        )
    }

    func testOldThresholdCannotReshieldAfterGrant() {
        let friday = date(27)
        var state = DailyScreenTimeState(deviceID: "device", limits: .init(weekdayMinutes: 5, weekendMinutes: 30))
        XCTAssertTrue(state.reach("weekday.5", at: friday, calendar: calendar))
        XCTAssertTrue(state.isExhausted(at: friday, calendar: calendar))
        XCTAssertTrue(state.bonuses.record(
            .init(id: "grant", minutes: 15, issuedAt: friday), at: friday, calendar: calendar
        ))
        XCTAssertFalse(state.isExhausted(at: friday, calendar: calendar))
        XCTAssertFalse(state.reach("weekday.5", at: friday, calendar: calendar))
        let extended = state.limits.threshold(at: friday, calendar: calendar, bonuses: state.bonuses)!
        XCTAssertTrue(state.reach(extended.name, at: friday, calendar: calendar))
        XCTAssertTrue(state.isExhausted(at: friday, calendar: calendar))
        XCTAssertFalse(state.reach(extended.name, at: friday, calendar: calendar))
        XCTAssertFalse(state.isExhausted(at: date(28), calendar: calendar))
        XCTAssertFalse(state.reach(extended.name, at: date(28), calendar: calendar))
        XCTAssertTrue(state.reach("weekend.30", at: date(28), calendar: calendar))
    }
}
