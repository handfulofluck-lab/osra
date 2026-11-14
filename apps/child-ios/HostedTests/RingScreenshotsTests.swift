import SwiftUI
import XCTest
@testable import FamilyShieldAgent

@MainActor
private final class ScreenshotRingBackend: RingBackend {
    let available = true
    private var ids = Set<UUID>()
    func requestAuthorization() async -> Bool { true }
    func schedule(_ id: UUID) async throws { ids.insert(id) }
    func stop(_ id: UUID) async throws { ids.remove(id) }
    func scheduledIDs() async -> Set<UUID> { ids }
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
        let originalLanguages = UserDefaults.standard.object(forKey: "AppleLanguages")
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
            if let originalLanguages {
                UserDefaults.standard.set(originalLanguages, forKey: "AppleLanguages")
            } else {
                UserDefaults.standard.removeObject(forKey: "AppleLanguages")
            }
            store.save(nil)
            defaults.removeObject(forKey: UserDefaultsRingHistory.key)
        }
        let id = UUID(uuidString: "6F1C2B8E-3D4A-4E5F-9A0B-1C2D3E4F5A6B")!
        let backend = ScreenshotRingBackend()
        let controller = RingController(backend: backend, store: store, history: history,
                                       reporter: ScreenshotReporter())
        await controller.start(id)
        defer { Task { await controller.stopForUnpair() } }

        for language in ["en", "ar"] {
            UserDefaults.standard.set([language], forKey: "AppleLanguages")
            XCTAssertEqual(L10n.tr("ring_title"), language == "en"
                           ? "Your parent is ringing this phone" : "هذا الهاتف يرنّ بطلب من والدك أو والدتك")
            for style in [UIUserInterfaceStyle.light, .dark] {
                for scale in [UIContentSizeCategory.large, .extraExtraExtraLarge] {
                    let window = UIWindow(frame: UIScreen.main.bounds)
                    let host = UIHostingController(rootView: RingView(controller: controller))
                    host.overrideUserInterfaceStyle = style
                    let container = UIViewController()
                    container.addChild(host)
                    container.view.addSubview(host.view)
                    host.view.frame = container.view.bounds
                    host.didMove(toParent: container)
                    container.setOverrideTraitCollection(UITraitCollection(preferredContentSizeCategory: scale), forChild: host)
                    window.rootViewController = container
                    window.makeKeyAndVisible()
                    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
                    let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
                    let image = renderer.image { _ in
                        window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                    }
                    let name = "ring-\(language)-\(style == .light ? "light" : "dark")\(scale == .large ? "" : "-large-text").png"
                    let data = try XCTUnwrap(image.pngData())
                    try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
                    XCTAssertGreaterThan(data.count, 1_000, name)
                    window.isHidden = true
                }
            }
        }
    }
}
