import Foundation

/// U14 (#650): the shield's colours, from the brand tokens (`docs/design/tokens.json`), with the contrast check that
/// keeps the main button readable. The primary button was dark blue words on the system's bright blue button; it now
/// uses the light brand `primary` (`#0B5D57`) with white words **in light and in dark alike**.
///
/// Why not the dark tokens: on a real iPhone 13 (13 Nov) the shield honoured a dynamic background colour but drew the
/// button label white whatever dynamic colour it was given, so `#7DB4FF` with "dark" words came out white on light
/// blue, 2.13:1. The UI/UX Bureau chose one fixed colour pair for this system-drawn screen. Do not make these dynamic.
public enum ShieldPalette {
    /// An sRGB colour as 0xRRGGBB.
    public struct RGB: Equatable {
        public let hex: UInt32
        public init(_ hex: UInt32) { self.hex = hex }
        public var red: Double { Double((hex >> 16) & 0xFF) / 255 }
        public var green: Double { Double((hex >> 8) & 0xFF) / 255 }
        public var blue: Double { Double(hex & 0xFF) / 255 }
    }

    /// The main button's background in both modes: the brand `primary` (light token).
    public static let buttonBackground = RGB(0x0B5D57)
    /// The main button's words in both modes: `onPrimary` (light token), white.
    public static let buttonLabel = RGB(0xFFFFFF)

    /// The WCAG 2 minimum for normal text, which a child pressing "Request access" must be able to read.
    public static let minimumContrast = 4.5

    /// WCAG 2 contrast ratio between two colours, from 1 to 21.
    public static func contrast(_ a: RGB, _ b: RGB) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    static func luminance(_ c: RGB) -> Double {
        func channel(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * channel(c.red) + 0.7152 * channel(c.green) + 0.0722 * channel(c.blue)
    }
}
