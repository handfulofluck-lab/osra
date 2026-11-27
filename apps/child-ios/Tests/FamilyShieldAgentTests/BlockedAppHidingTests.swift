import XCTest
@testable import FamilyShieldAgent

/// #1090: an app the child can see must keep its icon. `blockedApplications` does not block an app, it removes it from
/// the Home Screen and the App Library, so it is reserved for apps no shield can cover.
final class BlockedAppHidingTests: XCTestCase {

    private let youtube = "com.google.ios.youtube"
    private let safari = "com.apple.mobilesafari"

    func testAnAppWithATokenIsShieldedAndKeepsItsIcon() {
        let hidden = BlockedAppHiding.hiddenBundleIdentifiers([youtube, safari]) { $0 == youtube }
        XCTAssertEqual(hidden, [safari], "the tokenless app is hidden; the shielded one stays in the App Library")
    }

    func testNoTokenAtAllFallsBackToHidingSoTheRuleStillBlocks() {
        let hidden = BlockedAppHiding.hiddenBundleIdentifiers([youtube]) { _ in false }
        XCTAssertEqual(hidden, [youtube], "with no token there is no shield, so hiding is the only block left")
    }

    func testEveryAppWithATokenHidesNothing() {
        XCTAssertEqual(BlockedAppHiding.hiddenBundleIdentifiers([youtube, safari]) { _ in true }, [])
    }

    func testAnEmptyRuleHidesNothing() {
        XCTAssertEqual(BlockedAppHiding.hiddenBundleIdentifiers([]) { _ in false }, [])
    }

    /// The controller is iOS-only, so the wiring is read from the source: a rule that hides what it also shields is
    /// exactly the bug, and a pure policy nobody calls would not fix it.
    func testTheControllerHidesThroughThePolicy() throws {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/FamilyShieldAgent/ScreenTimeController.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        XCTAssertTrue(text.contains("BlockedAppHiding.hiddenBundleIdentifiers(packageIds)"),
                      "applyBlockedApps asks the policy which apps to hide")
        XCTAssertFalse(text.contains("store.application.blockedApplications = Set(packageIds.map"),
                       "every blocked app is no longer hidden, which moved the icons")
    }
}
