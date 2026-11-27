import XCTest
@testable import FamilyShieldAgent

/// #882: one button, three descriptions. The shield button says "Request access" (`block_request_access`), the
/// two App-groups footers said "Ask parent", and the alert this tap sends to the parent said it too.
///
/// The test is deliberately language-blind: it parses each shipped `.strings` file and requires both footers to
/// quote **the value of the button's own key** in that language. That way it holds for English and for Arabic
/// without embedding either translation here — the Arabic Bureau confirmed `main`'s Arabic already matches and
/// needs no edit, and this row fails if anyone edits it away.
///
/// Mutants this kills, all three observed while writing it:
/// 1. restoring `\"Ask parent\"` in either English footer — the footer no longer contains the button's value;
/// 2. restoring `"Child pressed 'Ask parent' on a shield screen."` — `requestAccessAlertBody` no longer names it;
/// 3. any edit to the Arabic footers, approved or not — the Arabic assertion is the one that notices.
final class RequestAccessWordingTests: XCTestCase {
    private let buttonKey = "block_request_access"
    private let footerKeys = ["groups_status_footer", "groups_new_footer"]

    private static var resourcesDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // FamilyShieldAgentTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // child-ios
            .appendingPathComponent("Sources/FamilyShieldAgent/Resources")
    }

    private func strings(in language: String) throws -> [String: String] {
        let url = Self.resourcesDirectory
            .appendingPathComponent("\(language).lproj")
            .appendingPathComponent("Localizable.strings")
        let text = try String(contentsOf: url, encoding: .utf8)
        return Self.parse(text)
    }

    /// `"key" = "value";` with `\"` and `\\` escapes, which is the only syntax these files use.
    static func parse(_ text: String) -> [String: String] {
        let pattern = #""((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [:] }
        var out: [String: String] = [:]
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        for match in regex.matches(in: text, range: range) {
            guard match.numberOfRanges == 3,
                  let keyRange = Range(match.range(at: 1), in: text),
                  let valueRange = Range(match.range(at: 2), in: text) else { continue }
            let key = String(text[keyRange])
            let raw = String(text[valueRange])
            out[key] = raw
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\\\", with: "\\")
        }
        return out
    }

    func testBothFootersQuoteTheButtonInEveryShippedLanguage() throws {
        for language in ["en", "ar"] {
            let table = try strings(in: language)
            let button = try XCTUnwrap(table[buttonKey], "no \(buttonKey) in \(language).lproj")
            for key in footerKeys {
                let footer = try XCTUnwrap(table[key], "no \(key) in \(language).lproj")
                XCTAssertTrue(
                    footer.contains(button),
                    "\(language) \(key) must quote the button's own wording (\(button)), not a second name for it: \(footer)"
                )
            }
        }
    }

    func testNoEnglishFooterStillNamesTheOldButton() throws {
        let table = try strings(in: "en")
        for key in footerKeys {
            let footer = try XCTUnwrap(table[key], "no \(key) in en.lproj")
            XCTAssertFalse(
                footer.contains("Ask parent"),
                "\(key) still says 'Ask parent', which no button says: \(footer)"
            )
        }
    }

    func testTheParentAlertNamesTheButtonTheChildPressed() {
        XCTAssertTrue(
            ShieldTapPolicy.requestAccessAlertBody.contains("Request access"),
            "the alert sent to the parent must name the button in front of the child: \(ShieldTapPolicy.requestAccessAlertBody)"
        )
        XCTAssertFalse(
            ShieldTapPolicy.requestAccessAlertBody.contains("Ask parent"),
            "the alert still names a button that does not exist: \(ShieldTapPolicy.requestAccessAlertBody)"
        )
    }
}
