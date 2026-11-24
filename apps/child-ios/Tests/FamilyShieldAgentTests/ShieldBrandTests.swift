import XCTest
@testable import FamilyShieldAgent

/// #881: the block screen is OSRA's, not Apple's. The shield used to pass `icon: nil` and `backgroundColor: nil`,
/// so iOS supplied its hourglass, its own background and its own "You cannot use … because it is restricted".
///
/// Two things make that fix honest rather than decorative:
/// - **Every colour is compared to `docs/design/tokens.json`**, and every mark number to `docs/design/brand/mark.svg`
///   (and its dark twin), so a design change turns this red instead of drifting silently.
/// - **The contrast floor is computed, not asserted in prose.** The spec asks for 4.5:1 on every text colour in both
///   modes; `contrast()` is WCAG 2.1 and the rows below name the three pairs.
///
/// Mutants this kills: any token value edited on one side only; a mark drawn with a different radius, stroke or dot
/// position; a colour pair that drops under 4.5:1 in either mode; and a subtitle that goes back to being empty.
final class ShieldBrandTests: XCTestCase {

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)          // …/Tests/FamilyShieldAgentTests/ShieldBrandTests.swift
            .deletingLastPathComponent()          // FamilyShieldAgentTests
            .deletingLastPathComponent()          // Tests
            .deletingLastPathComponent()          // child-ios
            .deletingLastPathComponent()          // apps
            .deletingLastPathComponent()          // repository
    }

    private static func text(_ relative: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relative), encoding: .utf8)
    }

    /// The shipped strings table for a language, read from the source tree: `ShieldText`'s own reader is private,
    /// and this test wants the file the app bundles, not a copy.
    private static func strings(_ language: String) throws -> [String: String] {
        let text = try text("apps/child-ios/Sources/FamilyShieldAgent/Resources/\(language).lproj/Localizable.strings")
        let pattern = #""((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [:] }
        var out: [String: String] = [:]
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        for match in regex.matches(in: text, range: range) {
            guard match.numberOfRanges == 3,
                  let keyRange = Range(match.range(at: 1), in: text),
                  let valueRange = Range(match.range(at: 2), in: text) else { continue }
            out[String(text[keyRange])] = String(text[valueRange])
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\\\", with: "\\")
        }
        return out
    }

    private static func firstMatch(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)) else {
            return nil
        }
        return (1..<match.numberOfRanges).map { index in
            guard let range = Range(match.range(at: index), in: text) else { return "" }
            return String(text[range])
        }
    }

    // MARK: - Tokens

    func testEveryColourComesFromTheDesignTokens() throws {
        let data = try Data(contentsOf: Self.repoRoot.appendingPathComponent("docs/design/tokens.json"))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let colours = try XCTUnwrap(json["color"] as? [String: Any])

        func hex(_ name: String) throws -> ShieldBrand.Hex {
            let entry = try XCTUnwrap(colours[name] as? [String: Any], "no \(name) in tokens.json")
            return ShieldBrand.Hex(light: try XCTUnwrap(entry["light"] as? String),
                                   dark: try XCTUnwrap(entry["dark"] as? String))
        }

        XCTAssertEqual(ShieldBrand.page, try hex("page"))
        XCTAssertEqual(ShieldBrand.primary, try hex("primary"))
        XCTAssertEqual(ShieldBrand.onPrimary, try hex("onPrimary"))
        XCTAssertEqual(ShieldBrand.ink, try hex("ink"))
        XCTAssertEqual(ShieldBrand.muted, try hex("muted"))
    }

    func testTheMarkIsTheArtworkFileInBothModes() throws {
        let light = try Self.text("docs/design/brand/mark.svg")
        let dark = try Self.text("docs/design/brand/mark-dark.svg")

        for (svg, expectedRing, expectedDot) in [(light, ShieldBrand.markRing.light, ShieldBrand.markDot.light),
                                                 (dark, ShieldBrand.markRing.dark, ShieldBrand.markDot.dark)] {
            let arc = try XCTUnwrap(Self.firstMatch(#"A([\d.]+) ([\d.]+)"#, in: svg), "no arc in \(svg.prefix(40))")
            XCTAssertEqual(Double(arc[0]) ?? 0, Double(ShieldBrand.ringRadius), accuracy: 0.001,
                           "the ring radius must be the SVG's")
            XCTAssertEqual(Double(arc[1]) ?? 0, Double(ShieldBrand.ringRadius), accuracy: 0.001)

            let stroke = try XCTUnwrap(Self.firstMatch(#"stroke-width="([\d.]+)""#, in: svg))
            XCTAssertEqual(Double(stroke[0]) ?? 0, Double(ShieldBrand.ringStroke), accuracy: 0.001)

            let dot = try XCTUnwrap(Self.firstMatch(#"circle cx="([\d.]+)" cy="([\d.]+)" r="([\d.]+)""#, in: svg))
            XCTAssertEqual(Double(dot[0]) ?? 0, Double(ShieldBrand.dotCenter.x), accuracy: 0.001)
            XCTAssertEqual(Double(dot[1]) ?? 0, Double(ShieldBrand.dotCenter.y), accuracy: 0.001)
            XCTAssertEqual(Double(dot[2]) ?? 0, Double(ShieldBrand.dotRadius), accuracy: 0.001)

            let ringHex = try XCTUnwrap(Self.firstMatch(#"<path[^>]*stroke="#([0-9A-Fa-f]{6})""#, in: svg))
            XCTAssertEqual(("#" + ringHex[0]).uppercased(), expectedRing.uppercased(),
                           "the drawn ring must be the colour in the artwork")

            let dotHex = try XCTUnwrap(Self.firstMatch(#"<circle[^>]*fill="#([0-9A-Fa-f]{6})""#, in: svg))
            XCTAssertEqual(("#" + dotHex[0]).uppercased(), expectedDot.uppercased(),
                           "the drawn dot must be the colour in the artwork")
        }
    }

    // MARK: - Contrast

    func testEveryTextColourClearsFourPointFiveToOneInBothModes() {
        let pairs: [(name: String, text: ShieldBrand.Hex, ground: ShieldBrand.Hex)] = [
            ("title on page", ShieldBrand.ink, ShieldBrand.page),
            ("subtitle on page", ShieldBrand.muted, ShieldBrand.page),
            ("primary button label", ShieldBrand.onPrimary, ShieldBrand.primary),
        ]
        for pair in pairs {
            for (mode, text, ground) in [("light", pair.text.light, pair.ground.light),
                                         ("dark", pair.text.dark, pair.ground.dark)] {
                let ratio = ShieldBrand.contrast(text, ground)
                XCTAssertNotNil(ratio, "\(pair.name) \(mode): one of \(text) / \(ground) is not a hex colour")
                XCTAssertGreaterThanOrEqual(ratio ?? 0, ShieldBrand.minimumContrast,
                                            "\(pair.name) in \(mode) is \(ratio ?? 0):1, under the 4.5:1 floor")
            }
        }
    }

    func testTheColourParserRefusesGarbageRatherThanReturningBlack() {
        XCTAssertNil(ShieldBrand.components("#12345"))
        XCTAssertNil(ShieldBrand.components("zzzzzz"))
        XCTAssertNotNil(ShieldBrand.components("#0B5D57"))
    }

    // MARK: - The subtitle is never empty

    func testTheShieldAlwaysHasASubtitleInBothLanguages() throws {
        for language in ["en", "ar"] {
            let table = try Self.strings(language)
            let fallback = try XCTUnwrap(table["block_subtitle_default"], "no block_subtitle_default in \(language)")
            XCTAssertFalse(fallback.trimmingCharacters(in: .whitespaces).isEmpty)

            for window in [nil, .bedtime(endsAt: "07:00"), .routine(name: "Homework", endsAt: "19:00"),
                           .routine(name: "   ", endsAt: "19:00")] as [ShieldText.Window?] {
                let subtitle = ShieldText.make(window: window, language: language).subtitle
                XCTAssertFalse(subtitle.trimmingCharacters(in: .whitespaces).isEmpty,
                               "\(language) with \(String(describing: window)) has an empty subtitle, which iOS fills itself")
            }
            // The default is only the fallback: a real window must still name itself.
            XCTAssertEqual(ShieldText.make(window: nil, language: language).subtitle, fallback)
            XCTAssertNotEqual(ShieldText.make(window: .bedtime(endsAt: "07:00"), language: language).subtitle, fallback)
        }
    }

    func testTheMarkIsDrawnAtTheSizeTheSpecAsksFor() {
        XCTAssertEqual(ShieldBrand.markPointSize, 60, "the spec asks for about 60 pt")
        // The mark must sit inside the middle 66% of its box, or a rounded mask clips it (BRAND.md §1).
        let furthest = max(ShieldBrand.ringRadius + ShieldBrand.ringStroke / 2,
                           (ShieldBrand.dotCenter.x + ShieldBrand.dotRadius) - ShieldBrand.markBox / 2)
        XCTAssertLessThanOrEqual(furthest, ShieldBrand.markBox * 0.5 * 0.66,
                                 "the mark reaches \(furthest) from the centre, past the 66% safe area")
    }
}
