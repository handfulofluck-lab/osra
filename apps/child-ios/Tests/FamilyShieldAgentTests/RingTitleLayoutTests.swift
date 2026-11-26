import XCTest
@testable import FamilyShieldAgent

/// #760, Arabic Language Bureau `7152533494` and UI/UX Bureau `7153247882`: at the largest text size the sentence that
/// explains the ring was cut. The fix is a heading that wraps and announces itself as the heading, and **no navigation
/// bar** — a bar would spend about 44 pt on a screen where first paint matters most. The view is iOS-only, so the
/// wiring is read from the source, as `ShieldTapPolicyTests` does for the shield.
final class RingTitleLayoutTests: XCTestCase {

    private func ringViewSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/FamilyShieldAgent/RingView.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testTheScreenHasNoNavigationBarToSpendSpaceOn() throws {
        let source = try ringViewSource()
        XCTAssertFalse(source.contains(".navigationTitle("),
                       "UI/UX ruled the bar out: it costs ~44 pt where first paint matters (7153247882)")
        XCTAssertFalse(source.contains(".navigationBarTitleDisplayMode("),
                       "a display mode without a title is dead code")
    }

    func testTheSentenceIsAWrappingHeadingVoiceOverAnnounces() throws {
        let source = try ringViewSource()
        XCTAssertTrue(source.contains(#"Text(L10n.tr("ring_title"))"#), "the sentence is the heading")
        XCTAssertTrue(source.contains(".fixedSize(horizontal: false, vertical: true)"),
                      "without this it is compacted onto one line, which is what cut it")
        XCTAssertTrue(source.contains(".accessibilityAddTraits(.isHeader)"),
                      "with no bar, the heading trait is what tells VoiceOver this is the heading")
    }

    func testTheEmbeddedPinFormAddsNoSecondHeading() throws {
        let ring = try ringViewSource()
        XCTAssertTrue(ring.contains("PinGateView(pin: $pin"), "the form is called without a title")
        let gate = try pinGateSource()
        XCTAssertTrue(gate.contains("if let title {"),
                      "the bar name is applied only when the caller gives one, so an embedded form adds no heading")
    }

    func testTheBellGivesWayToTheTextAtAccessibilitySizes() throws {
        let source = try ringViewSource()
        XCTAssertTrue(source.contains("@Environment(\\.dynamicTypeSize) private var dynamicTypeSize"),
                      "the view reads the text size")
        XCTAssertTrue(source.contains("if !dynamicTypeSize.isAccessibilitySize {"),
                      "at accessibility sizes the ~112 pt bell block is dropped so the explanation reaches first paint")
        // The block really is inside the condition: the circle comes after it, before the heading.
        let condition = try XCTUnwrap(source.range(of: "if !dynamicTypeSize.isAccessibilitySize {"))
        let circle = try XCTUnwrap(source.range(of: "Circle()"))
        let heading = try XCTUnwrap(source.range(of: #"Text(L10n.tr("ring_title"))"#))
        XCTAssertTrue(condition.upperBound < circle.lowerBound && circle.lowerBound < heading.lowerBound)
    }

    private func pinGateSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/FamilyShieldAgent/ParentPinViews.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testTheDroppedKeyIsGoneAndTheSentenceIsUntouched() throws {
        let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/FamilyShieldAgent/Resources")
        for language in ["en", "ar"] {
            let table = try String(contentsOf: resources.appendingPathComponent("\(language).lproj/Localizable.strings"),
                                   encoding: .utf8)
            XCTAssertFalse(table.contains("ring_nav_title"),
                           "the Bureau dropped its line for this screen, so the key leaves \(language) too")
        }
        XCTAssertEqual(L10n.tr("ring_title", language: "ar"), "هذا الهاتف يرنّ بطلب من والدك أو والدتك")
        XCTAssertEqual(L10n.tr("ring_title", language: "en"), "Your parent is ringing this phone")
    }
}
