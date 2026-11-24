import XCTest
@testable import FamilyShieldAgent

/// #880: the ringing permission. iOS asks to schedule alarms the first time a parent rings; a child who closes
/// that prompt hears nothing and the parent believes the phone is ringing. So the ask happens at setup, and a
/// refusal leaves a row whose only button goes to Settings — where the fix actually is.
///
/// The three rows below are the whole decision, and each one names the fault it prevents:
/// 1. a not-yet-asked phone offers the ask, and a refused one offers **Settings** — never the ask again, because
///    iOS will not show the prompt twice and a dead button is worse than no button;
/// 2. an approved phone, or one whose build cannot ring at all, shows nothing — a green "ringing is on" row would
///    be noise, and blaming a child for a build fact is wrong;
/// 3. the words are the Bureau's, so a paraphrase is caught here rather than in a child's hand.
final class AlarmRingingRowTests: XCTestCase {

    func testTheAskAndTheWayBackAreDifferentButtons() throws {
        let ask = try XCTUnwrap(AlarmRingingRow.of(.notDetermined))
        XCTAssertEqual(ask.action, .ask, "a phone that has never been asked must offer the ask")
        XCTAssertEqual(ask.body, "So your parent can ring this phone loudly if it's lost.")
        XCTAssertEqual(ask.buttonTitle, "Allow ringing")

        let denied = try XCTUnwrap(AlarmRingingRow.of(.denied))
        XCTAssertEqual(denied.action, .openSettings,
                       "iOS never shows its prompt twice, so a refused phone must go to Settings instead")
        XCTAssertEqual(denied.body, "Ringing is off on this iPhone.")
        XCTAssertEqual(denied.buttonTitle, "Turn on in Settings")
        XCTAssertNotEqual(denied.buttonTitle, ask.buttonTitle)
    }

    func testAnApprovedOrUnsupportedPhoneShowsNoRow() {
        XCTAssertNil(AlarmRingingRow.of(.approved), "nothing to fix, so nothing to show")
        XCTAssertNil(AlarmRingingRow.of(.notDetermined, available: false),
                     "a phone without AlarmKit must not blame the child")
        XCTAssertNil(AlarmRingingRow.of(.denied, available: false))
    }

    /// The Arabic Bureau issued five lines on `604` `7122208660`, including `alarm_setup_button`, which the UI/UX
    /// spec left open. This row fails if either shipped table loses one of them.
    func testBothLanguagesCarryTheBureausFourLines() throws {
        let keys = ["alarm_setup_body", "alarm_setup_button", "alarm_denied_row", "alarm_denied_button"]
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/FamilyShieldAgent/Resources")
        for language in ["en", "ar"] {
            let text = try String(contentsOf: root
                .appendingPathComponent("\(language).lproj")
                .appendingPathComponent("Localizable.strings"), encoding: .utf8)
            for key in keys {
                XCTAssertTrue(text.contains("\"\(key)\""), "\(language).lproj is missing \(key)")
            }
        }
    }
}
