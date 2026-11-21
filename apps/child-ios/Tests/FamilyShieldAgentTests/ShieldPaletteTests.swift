import XCTest
@testable import FamilyShieldAgent

/// U14 (#650): the shield's main button must be readable, at least 4.5:1, in light and dark.
final class ShieldPaletteTests: XCTestCase {
    func testTheContrastFormulaMatchesKnownValues() {
        XCTAssertEqual(ShieldPalette.contrast(.init(0x000000), .init(0xFFFFFF)), 21, accuracy: 0.01)
        XCTAssertEqual(ShieldPalette.contrast(.init(0xFFFFFF), .init(0xFFFFFF)), 1, accuracy: 0.001)
        XCTAssertEqual(ShieldPalette.contrast(.init(0x777777), .init(0xFFFFFF)), 4.48, accuracy: 0.02)
    }

    func testThePrimaryButtonIsReadable() {
        let ratio = ShieldPalette.contrast(ShieldPalette.buttonLabel, ShieldPalette.buttonBackground)
        XCTAssertGreaterThanOrEqual(ratio, ShieldPalette.minimumContrast, "\(ratio)")
    }

    /// The palette holds the brand tokens, so the shield looks like OSRA and a token change shows up here.
    func testThePaletteIsTheBrandTokens() throws {
        let tokensURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/design/tokens.json")
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: tokensURL)) as? [String: Any])
        let color = try XCTUnwrap(root["color"] as? [String: Any])
        func hex(_ name: String, _ theme: String) throws -> UInt32 {
            let token = try XCTUnwrap(color[name] as? [String: Any])
            let value = try XCTUnwrap(token[theme] as? String)
            return try XCTUnwrap(UInt32(value.dropFirst(), radix: 16))
        }
        XCTAssertEqual(ShieldPalette.buttonBackground.hex, try hex("primary", "light"))
        XCTAssertEqual(ShieldPalette.buttonLabel.hex, try hex("onPrimary", "light"))
    }

    /// The shield uses the fixed palette for the main button and `.label` for "Close app": never the old system
    /// blue/gray, and never a dynamic (light/dark) colour, which the shield draws wrong on a device (iPhone 13, 13 Nov).
    func testTheShieldUsesThePalette() throws {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/FamilyShieldAgent/ShieldConfiguration.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        XCTAssertTrue(text.contains("primaryButtonBackgroundColor: Self.color(ShieldPalette.buttonBackground)"))
        XCTAssertTrue(text.contains("color: Self.color(ShieldPalette.buttonLabel)"))
        XCTAssertFalse(text.contains("dynamicProvider"))
        XCTAssertFalse(text.contains("userInterfaceStyle"), "no light/dark switch on this system-drawn screen")
        XCTAssertTrue(text.contains("secondaryButtonLabel: ShieldConfiguration.Label(text: text.secondaryButton, color: .label)"))
        XCTAssertFalse(text.contains("color: .systemBlue"))
        XCTAssertFalse(text.contains("primaryButtonBackgroundColor: nil"))
    }
}
