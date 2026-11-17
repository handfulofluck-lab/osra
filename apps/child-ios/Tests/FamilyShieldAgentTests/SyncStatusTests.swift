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

    /// #661: the server address sits in a "Technical details" section at the bottom, closed until tapped.
    func testTheServerAddressIsUnderClosedTechnicalDetails() throws {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/FamilyShieldAgent/PairingView.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        XCTAssertTrue(text.contains("@State private var showTechnicalDetails = false"), "closed by default")
        let group = try XCTUnwrap(text.range(of: "DisclosureGroup(L10n.tr(\"status_technical_details\"), isExpanded: $showTechnicalDetails)"))
        let server = try XCTUnwrap(text.range(of: "LabeledContent(L10n.tr(\"status_server\")"))
        let repair = try XCTUnwrap(text.range(of: "L10n.tr(\"repair_button\")"))
        XCTAssertGreaterThan(server.lowerBound, group.lowerBound, "the server row is inside the section")
        XCTAssertGreaterThan(group.lowerBound, repair.lowerBound, "the section is the last one, below Pair again")
        XCTAssertEqual(text.components(separatedBy: "L10n.tr(\"status_server\")").count, 2, "the server row appears once")
        XCTAssertEqual(L10n.tr("status_technical_details", language: "en"), "Technical details")
        XCTAssertNotEqual(L10n.tr("status_technical_details", language: "ar"), "status_technical_details", "Arabic line present")
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
