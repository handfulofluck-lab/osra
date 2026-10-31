import XCTest
@testable import FamilyShieldAgent

/// #511: the iPhone block screen names the window holding the app and when it ends, in English and Arabic, with
/// the wording Karim approved for Android (#502: Q10 window line; Q12 title and buttons).
final class ShieldTextTests: XCTestCase {

    private let fsi = "\u{2068}"
    private let pdi = "\u{2069}"
    private let qatar = TimeZone(identifier: "Asia/Qatar")!
    private let utc = TimeZone(identifier: "UTC")!

    /// Monday 2 Nov 2026 at `hh:mm` in `zone`.
    private func monday(_ hh: Int, _ mm: Int, in zone: TimeZone) -> Date {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = zone
        return c.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: hh, minute: mm))!
    }

    private let homework = RuleStore.RoutineSchedule(
        name: "Homework", startTime: "17:00", endTime: "19:00",
        swiftWeekdays: [2], // Monday in Foundation numbering
        blockedApps: ["com.example.game"], allowedApps: [])

    private func window(_ app: String?, at now: Date, zone: TimeZone, routines: [RuleStore.RoutineSchedule] = [],
                        blocked: [String] = [], allowed: [String] = []) -> ShieldText.Window? {
        ShieldText.activeWindow(bundleIdentifier: app, now: now, timeZone: zone,
                                bedtimeStart: "21:00", bedtimeEnd: "07:00", routines: routines,
                                blocked: blocked, alwaysAllowed: [], allowed: allowed)
    }

    // MARK: - Which window

    func testBedtimeAndARoutineEachNameTheirWindowAndEnd() {
        XCTAssertEqual(window("com.example.game", at: monday(22, 0, in: utc), zone: utc), .bedtime(endsAt: "07:00"))
        XCTAssertEqual(window("com.example.game", at: monday(17, 30, in: utc), zone: utc, routines: [homework]),
                       .routine(name: "Homework", endsAt: "19:00"))
        XCTAssertNil(window("com.example.game", at: monday(19, 0, in: utc), zone: utc, routines: [homework]),
                     "the end of a window is outside it")
    }

    func testAPlainBlockAndAnAllowedAppNameNothing() {
        // Explicitly blocked: the rule itself, not a window, even inside bedtime.
        XCTAssertNil(window("com.example.game", at: monday(22, 0, in: utc), zone: utc, blocked: ["com.example.game"]))
        // Allowed by the parent: bedtime does not hold it.
        XCTAssertNil(window("com.example.reader", at: monday(22, 0, in: utc), zone: utc, allowed: ["com.example.reader"]))
        // The dialer is essential.
        XCTAssertNil(window("com.apple.mobilephone", at: monday(22, 0, in: utc), zone: utc))
        // A website shield is the web filter.
        XCTAssertNil(window(nil, at: monday(22, 0, in: utc), zone: utc))
        // Outside every window.
        XCTAssertNil(window("com.example.game", at: monday(12, 0, in: utc), zone: utc))
    }

    func testAnOvernightBedtimeIsReadOnTheGivenZoneNotThePhones() {
        // 20:00 UTC is 23:00 in Doha: inside a 21:00–07:00 bedtime there, outside it in UTC.
        let instant = monday(20, 0, in: utc)
        XCTAssertEqual(window("com.example.game", at: instant, zone: qatar), .bedtime(endsAt: "07:00"))
        XCTAssertNil(window("com.example.game", at: instant, zone: utc))
        // And after midnight it still ends the next morning.
        XCTAssertEqual(window("com.example.game", at: monday(3, 0, in: qatar), zone: qatar), .bedtime(endsAt: "07:00"))
    }

    func testAnOvernightRoutineCountsTheDayItStarted() {
        let late = RuleStore.RoutineSchedule(name: "Late", startTime: "22:00", endTime: "02:00",
                                             swiftWeekdays: [1], // Sunday
                                             blockedApps: ["com.example.game"], allowedApps: [])
        // Monday 01:00 is inside Sunday's 22:00–02:00 routine.
        XCTAssertEqual(window("com.example.game", at: monday(1, 0, in: utc), zone: utc, routines: [late]),
                       .routine(name: "Late", endsAt: "02:00"))
    }

    // MARK: - What it says

    func testTheWindowLineInEnglishAndArabic() {
        XCTAssertEqual(ShieldText.make(window: .bedtime(endsAt: "07:00"), language: "en").subtitle,
                       "Blocked by \(fsi)Bedtime\(pdi) until \(fsi)07:00\(pdi)")
        XCTAssertEqual(ShieldText.make(window: .bedtime(endsAt: "07:00"), language: "ar").subtitle,
                       "محجوب بسبب \(fsi)وقت النوم\(pdi) حتى \(fsi)07:00\(pdi)")
        XCTAssertEqual(ShieldText.make(window: .routine(name: "Homework", endsAt: "19:00"), language: "en").subtitle,
                       "Blocked by \(fsi)Homework\(pdi) until \(fsi)19:00\(pdi)")
    }

    func testNoWindowAndABlankRoutineNameShowNoLine() {
        XCTAssertNil(ShieldText.make(window: nil, language: "ar").subtitle)
        XCTAssertNil(ShieldText.make(window: .routine(name: "  ", endsAt: "19:00"), language: "en").subtitle)
    }

    func testTheArabicEqualsKarimsApprovedWordingLiterally() {
        // Pinned verbatim (the #486 / #491 / #502 pattern): a paraphrase is a change Karim did not approve.
        let ar = ShieldText.make(window: .bedtime(endsAt: "07:00"), language: "ar")
        XCTAssertEqual(ar.title, "حجب والدك أو والدتك هذا التطبيق")
        XCTAssertEqual(ar.primaryButton, "اطلب السماح")
        XCTAssertEqual(ar.secondaryButton, "الخروج إلى الشاشة الرئيسية")
        let en = ShieldText.make(window: nil, language: "en")
        XCTAssertEqual(en.title, "This app is blocked by your parent")
        XCTAssertEqual(en.primaryButton, "Request access")
        XCTAssertEqual(en.secondaryButton, "Exit to Home screen")
    }

    func testAnEnglishRoutineNameInTheArabicLineKeepsBothPlaceholdersInOrder() {
        let line = ShieldText.make(window: .routine(name: "Homework", endsAt: "19:00"), language: "ar").subtitle
        XCTAssertEqual(line, "محجوب بسبب \(fsi)Homework\(pdi) حتى \(fsi)19:00\(pdi)")
        let name = try? XCTUnwrap(line?.range(of: "Homework"))
        let time = try? XCTUnwrap(line?.range(of: "19:00"))
        XCTAssertNotNil(name)
        XCTAssertNotNil(time)
        if let name, let time { XCTAssertLessThan(name.lowerBound, time.lowerBound, "the window, then the time") }
    }

    func testAnUnshippedLanguageFallsBackToEnglish() {
        XCTAssertEqual(ShieldText.make(window: nil, language: "fr").title, "This app is blocked by your parent")
    }
}
