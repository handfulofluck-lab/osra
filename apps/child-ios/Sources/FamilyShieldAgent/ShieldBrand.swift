import Foundation
import CoreGraphics

/// #881: OSRA's own block screen. The shield used to show iOS's hourglass, a system background and iOS's own
/// "You cannot use … because it is restricted", so to a child it read as Apple's screen rather than their parent's.
///
/// Everything user-visible here comes from two sources that already exist, and the tests compare this file against
/// both rather than trusting the numbers typed below:
/// - **Colours:** `docs/design/tokens.json` (ADR-0038), light and dark pairs for `page`, `primary`, `onPrimary`,
///   `ink` and `muted`.
/// - **The mark:** `docs/design/brand/mark.svg` (light surfaces) and `mark-dark.svg` (dark), the O of OSRA drawn as
///   a parent's arm around a child — a ring of radius 26 with stroke 12, round ends, 270° open at the top right, and
///   a dot of radius 7.5 at (68.4, 31.6) in a 100 × 100 box, per `docs/design/BRAND.md` §1.
///
/// The mark is drawn rather than shipped as a bitmap: this repository is built by agents on machines without Xcode
/// or an SVG rasteriser, and a hand-exported PNG could not be regenerated or checked. The geometry below is the SVG's
/// own, and `ShieldBrandTests` reads the SVG and fails if the two ever disagree.
public enum ShieldBrand {

    // MARK: - Tokens (docs/design/tokens.json, colour.*)

    public struct Hex: Equatable {
        public let light: String
        public let dark: String
        public init(light: String, dark: String) {
            self.light = light
            self.dark = dark
        }
    }

    public static let page = Hex(light: "#F1F5F4", dark: "#0E1417")
    public static let primary = Hex(light: "#0B5D57", dark: "#7DB4FF")
    public static let onPrimary = Hex(light: "#FFFFFF", dark: "#0E1417")
    public static let ink = Hex(light: "#12211F", dark: "#E9EFF1")
    public static let muted = Hex(light: "#4D5E5A", dark: "#A7B6BD")

    // MARK: - The mark (mark.svg / mark-dark.svg)

    /// The mark's own colours: `mark.svg` draws the ring in `primary` light and the dot in `usageCategory.games`
    /// light; `mark-dark.svg` uses the dark pair. Read from the two SVGs so the drawn mark cannot drift from the file.
    public static let markRing = Hex(light: "#0B5D57", dark: "#7DB4FF")
    public static let markDot = Hex(light: "#C96A12", dark: "#FFB454")

    /// Geometry in the mark's own 100 × 100 box, copied from the SVG paths.
    public static let markBox: CGFloat = 100
    public static let ringRadius: CGFloat = 26
    public static let ringStroke: CGFloat = 12
    public static let dotCenter = CGPoint(x: 68.4, y: 31.6)
    public static let dotRadius: CGFloat = 7.5
    /// The arc runs from 0° (east, the point the SVG starts at) through 270°, leaving the top-right quadrant open.
    public static let ringEndAngle: CGFloat = 270

    /// The size the spec asks for on the shield: "about 60 pt", drawn from an artwork box of 100.
    public static let markPointSize: CGFloat = 60

    // MARK: - Colour maths (portable, so the contrast claim is testable without UIKit)

    /// `#RRGGBB` to components in 0…1. Nil for anything else, so a typo cannot silently produce black.
    public static func components(_ hex: String) -> (red: Double, green: Double, blue: Double)? {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
        return (Double((value >> 16) & 0xFF) / 255,
                Double((value >> 8) & 0xFF) / 255,
                Double(value & 0xFF) / 255)
    }

    /// WCAG 2.1 relative luminance.
    public static func luminance(_ hex: String) -> Double? {
        guard let c = components(hex) else { return nil }
        func channel(_ v: Double) -> Double {
            v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(c.red) + 0.7152 * channel(c.green) + 0.0722 * channel(c.blue)
    }

    /// WCAG contrast ratio between two `#RRGGBB` colours, 1…21. Nil when either cannot be parsed.
    public static func contrast(_ a: String, _ b: String) -> Double? {
        guard let la = luminance(a), let lb = luminance(b) else { return nil }
        let lighter = max(la, lb)
        let darker = min(la, lb)
        return (lighter + 0.05) / (darker + 0.05)
    }

    /// The spec's floor for every text colour on the shield, both modes.
    public static let minimumContrast: Double = 4.5
}

#if os(iOS)
import UIKit

/// UIKit side: the tokens as dynamic colours (so the extension follows the phone's appearance) and the mark as a
/// `UIImage` for `ShieldConfiguration.icon`.
public extension ShieldBrand {

    static func color(_ hex: Hex) -> UIColor {
        dynamic(light: hex.light, dark: hex.dark)
    }

    /// A colour that resolves again whenever the trait collection changes, which is what a shield needs: the same
    /// configuration object is reused as the system flips between light and dark.
    static func dynamic(light: String, dark: String) -> UIColor {
        let lightColor = uiColor(light) ?? .black
        let darkColor = uiColor(dark) ?? .white
        return UIColor { traits in
            traits.userInterfaceStyle == .dark ? darkColor : lightColor
        }
    }

    static func uiColor(_ hex: String) -> UIColor? {
        guard let c = components(hex) else { return nil }
        return UIColor(red: c.red, green: c.green, blue: c.blue, alpha: 1)
    }

    /// The OSRA mark, drawn from the SVG's geometry at `size` points. Never the system hourglass.
    static func markImage(size: CGFloat = markPointSize) -> UIImage {
        let scale = size / markBox
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        return renderer.image { context in
            let cg = context.cgContext
            cg.setLineCap(.round)
            cg.setLineWidth(ringStroke * scale)
            cg.setStrokeColor(color(markRing).cgColor)
            let centre = CGPoint(x: markBox / 2 * scale, y: markBox / 2 * scale)
            let radius = ringRadius * scale
            cg.addArc(center: centre,
                      radius: radius,
                      startAngle: 0,
                      endAngle: ringEndAngle * .pi / 180,
                      clockwise: true)
            cg.strokePath()

            cg.setFillColor(color(markDot).cgColor)
            let dot = dotCenter
            let rect = CGRect(x: (dot.x - dotRadius) * scale,
                              y: (dot.y - dotRadius) * scale,
                              width: dotRadius * 2 * scale,
                              height: dotRadius * 2 * scale)
            cg.fillEllipse(in: rect)
        }
    }
}
#endif
