import XCTest
@testable import FamilyShieldAgent

/// Exercises only the pure window logic so the suite runs on macOS CI without
/// Screen Time entitlements (spec §6 test strategy).
final class FamilyShieldAgentTests: XCTestCase {

    // Bedtime window 21:00 -> 07:00 wraps around local midnight.
    func testBedtimeWindowWrapsMidnight() {
        let window = RoutineWindow(startHour: 21, startMinute: 0, endHour: 7, endMinute: 0)

        XCTAssertTrue(window.wrapsMidnight)

        // Evening side of the window (start is inclusive).
        XCTAssertTrue(window.contains(minutesOfDay: 21 * 60))
        XCTAssertTrue(window.contains(minutesOfDay: 23 * 60 + 30))

        // Overnight side of the window.
        XCTAssertTrue(window.contains(minutesOfDay: 0))
        XCTAssertTrue(window.contains(minutesOfDay: 6 * 60 + 59))

        // Outside the window (end is exclusive).
        XCTAssertFalse(window.contains(minutesOfDay: 7 * 60))
        XCTAssertFalse(window.contains(minutesOfDay: 12 * 60))
        XCTAssertFalse(window.contains(minutesOfDay: 20 * 60 + 59))
    }

    // Daytime window 08:30 -> 15:45 does not wrap.
    func testDaytimeWindowWithoutWrap() {
        let window = RoutineWindow(startHour: 8, startMinute: 30, endHour: 15, endMinute: 45)

        XCTAssertFalse(window.wrapsMidnight)

        XCTAssertFalse(window.contains(minutesOfDay: 8 * 60 + 29))
        XCTAssertTrue(window.contains(minutesOfDay: 8 * 60 + 30))
        XCTAssertTrue(window.contains(minutesOfDay: 15 * 60 + 44))
        XCTAssertFalse(window.contains(minutesOfDay: 15 * 60 + 45))
    }

    // Pure static helper drives the wrap-around logic.
    func testIsWithinWindowStaticHelper() {
        XCTAssertTrue(RoutineWindow.isWithinWindow(minutesOfDay: 3 * 60, startMinutes: 22 * 60, endMinutes: 6 * 60))
        XCTAssertFalse(RoutineWindow.isWithinWindow(minutesOfDay: 12 * 60, startMinutes: 22 * 60, endMinutes: 6 * 60))
        XCTAssertTrue(RoutineWindow.isWithinWindow(minutesOfDay: 8 * 60, startMinutes: 8 * 60, endMinutes: 17 * 60))
        XCTAssertFalse(RoutineWindow.isWithinWindow(minutesOfDay: 17 * 60, startMinutes: 8 * 60, endMinutes: 17 * 60))
    }

    // Full-day window 00:00 -> 24:00 (endMinutes 1440, unbounded) contains every time of day.
    func testFullDayWindowIsUnbounded() {
        let window = RoutineWindow(startHour: 0, startMinute: 0, endHour: 24, endMinute: 0)

        XCTAssertEqual(1440, window.endMinutes)
        XCTAssertFalse(window.wrapsMidnight)

        XCTAssertTrue(window.contains(minutesOfDay: 0))
        XCTAssertTrue(window.contains(minutesOfDay: 12 * 60))
        XCTAssertTrue(window.contains(minutesOfDay: 23 * 60 + 59))
    }

    // Evening window 18:00 -> 24:00 (endMinutes 1440) starts at 18:00 and never closes.
    func testUnboundedWindowFromEveningStart() {
        let window = RoutineWindow(startHour: 18, startMinute: 0, endHour: 24, endMinute: 0)

        XCTAssertFalse(window.wrapsMidnight)

        XCTAssertFalse(window.contains(minutesOfDay: 17 * 60 + 59))
        XCTAssertTrue(window.contains(minutesOfDay: 18 * 60))
        XCTAssertTrue(window.contains(minutesOfDay: 23 * 60 + 59))

        // Static helper agrees with the instance form.
        XCTAssertTrue(RoutineWindow.isWithinWindow(minutesOfDay: 22 * 60, startMinutes: 18 * 60, endMinutes: 1440))
        XCTAssertFalse(RoutineWindow.isWithinWindow(minutesOfDay: 9 * 60, startMinutes: 18 * 60, endMinutes: 1440))
    }

    // Date-based containment evaluated against an explicit GMT calendar.
    func testContainsDateUsesGivenCalendar() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "GMT")!

        let window = RoutineWindow(startHour: 21, startMinute: 0, endHour: 7, endMinute: 0)

        let lateEvening = calendar.date(from: DateComponents(year: 2026, month: 9, day: 14, hour: 23, minute: 30))!
        let midday = calendar.date(from: DateComponents(year: 2026, month: 9, day: 14, hour: 12, minute: 0))!

        XCTAssertTrue(window.contains(lateEvening, calendar: calendar))
        XCTAssertFalse(window.contains(midday, calendar: calendar))
    }

    // Schedule components conversion tests (IOS-06).
    func testScheduleComponentsHandlesOvernightWrap() {
        let window = RoutineWindow(startHour: 21, startMinute: 30, endHour: 7, endMinute: 0)
        let (start, end) = window.toScheduleComponents()
        XCTAssertEqual(21, start.hour)
        XCTAssertEqual(30, start.minute)
        XCTAssertEqual(7, end.hour)
        XCTAssertEqual(0, end.minute)
    }

    func testScheduleComponentsHandlesUnboundedEndOfDay() {
        let window = RoutineWindow(startHour: 20, startMinute: 0, endHour: 24, endMinute: 0)
        let (start, end) = window.toScheduleComponents()
        XCTAssertEqual(20, start.hour)
        XCTAssertEqual(0, start.minute)
        XCTAssertEqual(23, end.hour)
        XCTAssertEqual(59, end.minute)
    }

    func testScheduleComponentsHandlesWholeDay() {
        let window = RoutineWindow(startMinutes: 0, endMinutes: 0)
        let (start, end) = window.toScheduleComponents()
        XCTAssertEqual(0, start.hour)
        XCTAssertEqual(0, start.minute)
        XCTAssertEqual(23, end.hour)
        XCTAssertEqual(59, end.minute)
    }
}
