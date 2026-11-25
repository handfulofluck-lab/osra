#if os(iOS)
import XCTest
import UIKit
@testable import FamilyShieldAgent

/// #881: the mark is drawn, not shipped, so its **pixels** are the thing under test.
///
/// These rows exist because a review of the first version found two defects that every value-based test in
/// `ShieldBrandTests` passed straight through:
/// 1. `CGContext.addArc(…, clockwise: true)` in a `UIGraphicsImageRenderer` context (Y down) sweeps the **90°
///    complement** — the short arc through the dot — instead of the mark's 270° ring. Nothing about the numbers
///    (radius 26, stroke 12) is wrong; only what got painted.
/// 2. Drawing with the dynamic `UIColor` baked whichever variant `UITraitCollection.current` happened to be —
///    light, inside a headless extension — so a dark shield got the light ring at 2.4:1.
///
/// iOS-only on purpose: it needs `UIKit`, and the macOS job must not count it (the discovery guard pins 234).
final class ShieldMarkRenderTests: XCTestCase {

    private func pixel(_ image: UIImage, at point: CGPoint) -> (r: Int, g: Int, b: Int, a: Int) {
        let scale = image.scale
        let width = Int(image.size.width * scale)
        let height = Int(image.size.height * scale)
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let space = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: &data, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let cg = image.cgImage else {
            XCTFail("could not read the rendered mark")
            return (0, 0, 0, 0)
        }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        let x = min(width - 1, max(0, Int(point.x * scale)))
        let y = min(height - 1, max(0, Int(point.y * scale)))
        let i = (y * width + x) * 4
        return (Int(data[i]), Int(data[i + 1]), Int(data[i + 2]), Int(data[i + 3]))
    }

    private func assertColour(_ actual: (r: Int, g: Int, b: Int, a: Int), _ hex: String,
                              _ message: String, tolerance: Int = 12) {
        guard let expected = ShieldBrand.components(hex) else { return XCTFail("bad hex \(hex)") }
        XCTAssertEqual(actual.a, 255, "\(message): nothing was painted")
        XCTAssertEqual(actual.r, Int(expected.red * 255), accuracy: tolerance, "\(message): red")
        XCTAssertEqual(actual.g, Int(expected.green * 255), accuracy: tolerance, "\(message): green")
        XCTAssertEqual(actual.b, Int(expected.blue * 255), accuracy: tolerance, "\(message): blue")
    }

    /// The ring is the 270° arc, not its complement: South-West must be painted and the top-right gap must not.
    func testTheRingIsThreeQuartersAndOpenAtTheTopRight() {
        let image = ShieldBrand.renderMark(size: 100, ring: ShieldBrand.markRing.light, dot: ShieldBrand.markDot.light)
        // On the ring, at 225°: centre + 26·(cos 225°, sin 225°) = (31.6, 68.4).
        assertColour(pixel(image, at: CGPoint(x: 31.6, y: 68.4)), ShieldBrand.markRing.light,
                     "the South-West of the ring is empty, so the arc swept the wrong way")
        // Also West, to be sure it is a sweep and not one lucky point.
        assertColour(pixel(image, at: CGPoint(x: 24, y: 50)), ShieldBrand.markRing.light, "the West of the ring is empty")
        // The gap between the two ends, just off East-North-East: nothing there but background.
        let gap = pixel(image, at: CGPoint(x: 74, y: 40))
        XCTAssertEqual(gap.a, 0, "the ring's opening at the top right is filled in: \(gap)")
        // The dot sits in that opening.
        assertColour(pixel(image, at: CGPoint(x: 68.4, y: 31.6)), ShieldBrand.markDot.light, "the dot is missing")
    }

    /// The shield follows the phone: asking the asset for each appearance must give that artwork's colours.
    func testTheMarkHasALightAndADarkVariant() throws {
        let asset = ShieldBrand.markImageAsset(size: 100)
        // The query has to carry the scale as well as the appearance, or `UIImageAsset` hands back a normalised
        // `@1x` image whose point size no longer matches the pixels that were drawn.
        let scale = UITraitCollection.current.displayScale
        func image(_ style: UIUserInterfaceStyle) -> UIImage {
            asset.image(with: UITraitCollection(traitsFrom: [
                UITraitCollection(displayScale: scale),
                UITraitCollection(userInterfaceStyle: style),
            ]))
        }
        let light = image(.light)
        let dark = image(.dark)
        XCTAssertEqual(light.size, CGSize(width: 100, height: 100), "the asset must keep the drawn point size")
        XCTAssertEqual(dark.size, CGSize(width: 100, height: 100))
        assertColour(pixel(light, at: CGPoint(x: 31.6, y: 68.4)), ShieldBrand.markRing.light, "light ring")
        assertColour(pixel(dark, at: CGPoint(x: 31.6, y: 68.4)), ShieldBrand.markRing.dark, "dark ring")
        assertColour(pixel(light, at: CGPoint(x: 68.4, y: 31.6)), ShieldBrand.markDot.light, "light dot")
        assertColour(pixel(dark, at: CGPoint(x: 68.4, y: 31.6)), ShieldBrand.markDot.dark, "dark dot")
    }
}
#endif
