import CoreImage
import SwiftUI
import XCTest
@testable import FamilyShieldAgent

@MainActor
private func titleImageData(in image: UIImage) throws -> Data {
    let crop = CGRect(x: image.size.width * 0.05, y: 300,
                      width: image.size.width * 0.9, height: 100)
    let format = UIGraphicsImageRendererFormat()
    format.scale = image.scale
    let renderer = UIGraphicsImageRenderer(size: crop.size, format: format)
    let cropped = renderer.image { _ in
        image.draw(at: CGPoint(x: -crop.minX, y: -crop.minY))
    }
    return try XCTUnwrap(cropped.pngData())
}

@MainActor
private func pixel(in image: UIImage, x: CGFloat, y: CGFloat) throws -> [UInt8] {
    let source = try XCTUnwrap(image.cgImage)
    var bytes = [UInt8](repeating: 0, count: 4)
    CIContext().render(CIImage(cgImage: source), toBitmap: &bytes, rowBytes: 4,
                       bounds: CGRect(x: x, y: CGFloat(source.height) - y - 1, width: 1, height: 1),
                       format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
    return bytes
}

@MainActor
private final class ScreenshotRingBackend: RingBackend {
    let available = true
    private var ids = Set<UUID>()
    func requestAuthorization() async -> Bool { true }
    func schedule(_ id: UUID) async throws { ids.insert(id) }
    func stop(_ id: UUID) async throws { ids.remove(id) }
    func scheduledIDs() async throws -> Set<UUID> { ids }
    func updates() async -> AsyncStream<Set<UUID>> { AsyncStream { $0.finish() } }
}

@MainActor
private struct ScreenshotReporter: RingAlertReporting {
    func report(state: RingEventState, ringId: UUID, dismissalCount: Int,
                afterRestart: Bool) async -> RingReportOutcome { .delivered }
}

@MainActor
final class RingScreenshotsTests: XCTestCase {
    func testCaptureRingViewInBothLanguagesThemesAndTextSizes() async throws {
        guard let directory = ProcessInfo.processInfo.environment["OSRA_RING_SCREENSHOT_DIR"] else {
            throw XCTSkip("Manual screenshot capture only")
        }
        let fileManager = FileManager.default
        try fileManager.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "RingScreenshotsTests"))
        let store = UserDefaultsRingStore(defaults: defaults)
        let history = UserDefaultsRingHistory(defaults: defaults)
        let keychain = KeychainSecretStore()
        AgentIdentityStore.secrets = keychain
        let previousPin = keychain.read(ParentPinStore.account)
        if previousPin == nil {
            XCTAssertTrue(keychain.write("pbkdf2$1$AA==$AA==", for: ParentPinStore.account))
        }
        defer {
            if let previousPin {
                keychain.write(previousPin, for: ParentPinStore.account)
            } else {
                keychain.delete(ParentPinStore.account)
            }
            store.save(nil)
            defaults.removeObject(forKey: UserDefaultsRingHistory.key)
        }
        let id = UUID(uuidString: "6F1C2B8E-3D4A-4E5F-9A0B-1C2D3E4F5A6B")!
        let backend = ScreenshotRingBackend()
        let controller = RingController(backend: backend, store: store, history: history,
                                       reporter: ScreenshotReporter())
        _ = await controller.start(id)
        defer { Task { await controller.stopForUnpair() } }

        let language = try XCTUnwrap(ProcessInfo.processInfo.environment["OSRA_RING_SCREENSHOT_LANGUAGE"])
        XCTAssertEqual(L10n.tr("ring_title"), L10n.tr("ring_title", language: language),
                       "The -testLanguage launch must select the requested resource bundle")
        let windowScene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        for style in [UIUserInterfaceStyle.light, .dark] {
            var titles = [Data]()
            for scale in [UIContentSizeCategory.large, .extraExtraExtraLarge] {
                let typeSize: DynamicTypeSize = scale == .large ? .large : .xxxLarge
                let window = UIWindow(windowScene: windowScene)
                window.frame = windowScene.screen.bounds
                let host = UIHostingController(rootView: RingView(controller: controller)
                    .environment(\.dynamicTypeSize, typeSize))
                host.overrideUserInterfaceStyle = style
                let container = UIViewController()
                container.view.frame = window.bounds
                container.addChild(host)
                container.view.addSubview(host.view)
                host.view.frame = container.view.bounds
                host.didMove(toParent: container)
                window.rootViewController = container
                window.makeKeyAndVisible()
                try await Task.sleep(nanoseconds: 200_000_000)
                let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
                let image = renderer.image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                let name = "ring-\(language)-\(style == .light ? "light" : "dark")\(scale == .large ? "" : "-large-text").png"
                let data = try XCTUnwrap(image.pngData())
                try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
                XCTAssertGreaterThan(data.count, 1_000, name)
                titles.append(try titleImageData(in: image))
                let pagePixel = try pixel(in: image, x: image.size.width * image.scale * 0.01,
                                          y: image.size.height * image.scale * 0.65)
                let formPixel = try pixel(in: image, x: image.size.width * image.scale * 0.075,
                                          y: image.size.height * image.scale * 0.65)
                XCTAssertEqual(formPixel, pagePixel, "\(name): PIN form must share the ring page background")
                window.isHidden = true
            }
            XCTAssertEqual(titles.count, 2)
            XCTAssertNotEqual(titles[0], titles[1], "The ring title must respond to Dynamic Type")
        }
    }
}
