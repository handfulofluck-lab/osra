import XCTest
@testable import FamilyShieldAgent

/// #602 items 3 and 4: the status screen says when it last synced, turns amber after 30 minutes, and a manual
/// sync reports whether it reached the server.
final class SyncStatusTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let en = Locale(identifier: "en_US")

    func testTheStateFollowsTheThreshold() {
        XCTAssertEqual(SyncStatus.state(syncedAt: nil, now: now), .never)
        let recent = now.addingTimeInterval(-120)
        XCTAssertEqual(SyncStatus.state(syncedAt: recent, now: now), .fresh(recent))
        let edge = now.addingTimeInterval(-SyncStatus.staleAfter)
        XCTAssertEqual(SyncStatus.state(syncedAt: edge, now: now), .fresh(edge), "30 minutes is still fresh")
        let old = now.addingTimeInterval(-SyncStatus.staleAfter - 1)
        XCTAssertEqual(SyncStatus.state(syncedAt: old, now: now), .stale(old))
    }

    func testTheEnglishLines() {
        XCTAssertEqual(SyncStatus.text(.never, now: now, locale: en, language: "en"), "Not synced yet")
        let fresh = SyncStatus.text(.fresh(now.addingTimeInterval(-120)), now: now, locale: en, language: "en")
        XCTAssertEqual(fresh, "Last synced 2 minutes ago")
        let stale = SyncStatus.text(.stale(now.addingTimeInterval(-45 * 60)), now: now, locale: en, language: "en")
        XCTAssertEqual(stale, "Not synced for 45 minutes. Check the internet connection, then tap \"Sync now\".")
    }

    func testTheArabicLinesUseTheApprovedWording() {
        let ar = Locale(identifier: "ar")
        XCTAssertEqual(SyncStatus.text(.never, now: now, locale: ar, language: "ar"), "لم يتم التحديث بعد")
        XCTAssertTrue(SyncStatus.text(.fresh(now.addingTimeInterval(-120)), now: now, locale: ar, language: "ar")
            .hasPrefix("آخر تحديث: "))
        XCTAssertTrue(SyncStatus.text(.stale(now.addingTimeInterval(-45 * 60)), now: now, locale: ar, language: "ar")
            .hasPrefix("لم يتم التحديث منذ "))
    }

    func testAManualSyncSucceedsOnlyWhenTheServerAnswered() {
        XCTAssertFalse(SyncStatus.succeeded(.failed("offline")))
        XCTAssertFalse(SyncStatus.succeeded(.notPaired))
        XCTAssertTrue(SyncStatus.succeeded(.consentWithdrawn))
    }

    func testTheStatusScreenShowsNoRawIds() throws {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/FamilyShieldAgent/PairingView.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        XCTAssertFalse(text.contains("value: identity.childId"), "no child id on screen")
        XCTAssertFalse(text.contains("value: identity.deviceId"), "no device id on screen")
        XCTAssertTrue(text.contains("value: name"), "the child's name instead")
        XCTAssertTrue(text.contains("L10n.tr(\"status_sync_now\")"), "a Sync now button")
    }
}
