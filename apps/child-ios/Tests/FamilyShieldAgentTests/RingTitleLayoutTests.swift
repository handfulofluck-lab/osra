import XCTest
@testable import FamilyShieldAgent

/// #760, Arabic Language Bureau `7152533494`: the ring screen's bar name must be short enough to survive the largest
/// text size, and the sentence that explains the ring must keep the width it needs to wrap. The view is iOS-only, so
/// the wiring is read from the source, as `ShieldTapPolicyTests` does for the shield.
final class RingTitleLayoutTests: XCTestCase {

    private func ringViewSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/FamilyShieldAgent/RingView.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testTheBarCarriesTheShortNameAndNotTheSentence() throws {
        let source = try ringViewSource()
        XCTAssertTrue(source.contains(#".navigationTitle(L10n.tr("ring_nav_title"))"#),
                      "the bar takes the short key the Bureau issued")
        XCTAssertFalse(source.contains(#".navigationTitle(L10n.tr("ring_title"))"#),
                       "the whole sentence in the bar is the defect: it cannot fit at the largest text")
    }

    func testTheSentenceStaysAsAWrappingHeading() throws {
        let source = try ringViewSource()
        XCTAssertTrue(source.contains(#"Text(L10n.tr("ring_title"))"#), "the sentence is still the heading")
        XCTAssertTrue(source.contains(".fixedSize(horizontal: false, vertical: true)"),
                      "the heading refuses single-line compaction, which is what cut it")
    }

    func testBothKeysTheBureauSplitArePresent() {
        XCTAssertEqual(L10n.tr("ring_nav_title", language: "ar"), "رنين الهاتف")
        XCTAssertEqual(L10n.tr("ring_title", language: "ar"), "هذا الهاتف يرنّ بطلب من والدك أو والدتك")
        XCTAssertEqual(L10n.tr("ring_nav_title", language: "en"), "Phone ringing")
    }
}
