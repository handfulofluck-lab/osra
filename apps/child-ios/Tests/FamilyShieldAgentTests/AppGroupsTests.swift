import XCTest
@testable import FamilyShieldAgent

/// ADR-0037 (#372 PR A): app groups, driven with a plain Codable stand-in for `FamilyActivitySelection`, so no
/// test touches FamilyControls. The shield itself is checked on the iPhone 13 (PR §5).
final class AppGroupsTests: XCTestCase {

    /// Stands in for the picker's selection: three sets of opaque ids.
    struct FakeSelection: AppGroupSelection, Equatable {
        var apps: Set<String> = []
        var categories: Set<String> = []
        var sites: Set<String> = []
        var counts: AppGroupCounts { AppGroupCounts(apps: apps.count, categories: categories.count, sites: sites.count) }
    }

    private var defaults: UserDefaults!
    private let suite = "AppGroupsTests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    // MARK: - The label is child-phone input

    func testTheLabelIsTrimmedFoldedAndCapped() {
        XCTAssertEqual(AppGroupLabel.sanitize("  Games  "), "Games")
        XCTAssertEqual(AppGroupLabel.sanitize("Home\n\twork"), "Home work")
        XCTAssertEqual(AppGroupLabel.sanitize("a\u{0007}b"), "ab", "control characters go")
        XCTAssertEqual(AppGroupLabel.sanitize(String(repeating: "x", count: 100))?.count, AppGroupLabel.maxLength)
        XCTAssertEqual(AppGroupLabel.sanitize("ألعاب"), "ألعاب")
        XCTAssertNil(AppGroupLabel.sanitize("   \n "))
        // ADR-0037 B2: direction controls go too, as the server refuses them.
        XCTAssertEqual(AppGroupLabel.sanitize("Ga\u{202E}mes"), "Games")
        XCTAssertEqual(AppGroupLabel.sanitize("\u{2066}ألعاب\u{2069}"), "ألعاب")
        XCTAssertEqual(AppGroupLabel.sanitize("a\u{200F}b\u{061C}c"), "abc")
    }

    // MARK: - Editing

    func testAGroupGetsAFreshUUIDAndACleanLabel() throws {
        var list = AppGroupList<FakeSelection>()
        let id = try XCTUnwrap(list.add(label: " Games ", selection: FakeSelection(apps: ["calc"])))
        XCTAssertNotNil(UUID(uuidString: id), "the id is a random UUID made on the phone")
        let other = try XCTUnwrap(list.add(label: "Games", selection: FakeSelection(apps: ["calc"])))
        XCTAssertNotEqual(id, other)
        XCTAssertEqual(list.groups.first?.label, "Games")
    }

    func testAnEmptyLabelOrAFullListAddsNothing() {
        var list = AppGroupList<FakeSelection>()
        XCTAssertNil(list.add(label: "  ", selection: FakeSelection()))
        for i in 0..<AppGroupList<FakeSelection>.maxGroups { XCTAssertNotNil(list.add(label: "g\(i)", selection: FakeSelection())) }
        XCTAssertNil(list.add(label: "one more", selection: FakeSelection()))
        XCTAssertEqual(list.groups.count, AppGroupList<FakeSelection>.maxGroups)
    }

    func testOnlyBlockedGroupsReachTheShield() throws {
        var list = AppGroupList<FakeSelection>()
        let games = try XCTUnwrap(list.add(label: "Games", selection: FakeSelection(apps: ["calc", "chess"]), blocked: true))
        _ = list.add(label: "School", selection: FakeSelection(apps: ["notes"]), blocked: false)
        XCTAssertEqual(list.blockedSelections, [FakeSelection(apps: ["calc", "chess"])],
                       "never every picked token, only the blocked groups'")
        list.setBlocked(false, id: games)
        XCTAssertTrue(list.blockedSelections.isEmpty)
    }

    func testChangingRenamingAndDeleting() throws {
        var list = AppGroupList<FakeSelection>()
        let id = try XCTUnwrap(list.add(label: "Games", selection: FakeSelection(apps: ["calc"]), blocked: true))
        list.setSelection(FakeSelection(apps: ["calc", "chess"], sites: ["example"]), id: id)
        XCTAssertEqual(list.groups.first?.counts, AppGroupCounts(apps: 2, categories: 0, sites: 1))
        XCTAssertTrue(list.rename("  Fun ", id: id))
        XCTAssertFalse(list.rename(" ", id: id))
        XCTAssertEqual(list.groups.first?.label, "Fun")
        list.remove(id: id)
        XCTAssertTrue(list.groups.isEmpty)
    }

    // MARK: - Counts, the most the server will ever see

    func testTheSummaryReadsNaturallyAndSaysWhenNothingIsLeft() {
        XCTAssertEqual(AppGroupCounts(apps: 1, categories: 0, sites: 0).summary, "1 app")
        XCTAssertEqual(AppGroupCounts(apps: 5, categories: 1, sites: 2).summary, "5 apps, 1 category, 2 websites")
        XCTAssertEqual(AppGroupCounts(apps: 0, categories: 3, sites: 0).summary, "3 categories")
        XCTAssertEqual(AppGroupCounts(apps: 0, categories: 0, sites: 0).summary, "Nothing chosen")
        XCTAssertTrue(AppGroupCounts(apps: 0, categories: 0, sites: 0).isEmpty)
    }

    // MARK: - Blocks from the parent app (ADR-0037 PR B3)

    func testAGroupTheParentAppBlocksIsShieldedAsWell() throws {
        var list = AppGroupList<FakeSelection>()
        let games = try XCTUnwrap(list.add(label: "Games", selection: FakeSelection(apps: ["g"]), blocked: false))
        _ = try XCTUnwrap(list.add(label: "Video", selection: FakeSelection(apps: ["v"]), blocked: false))
        XCTAssertEqual(list.blockedSelections, [], "nothing blocked on the phone")
        XCTAssertEqual(list.blockedSelections(alsoBlocked: [games.lowercased()]), [FakeSelection(apps: ["g"])],
                       "the phone's upper-case id matches the lowercased server id")
        XCTAssertTrue(list.isBlockedByParentApp(id: games, serverBlocked: [games.lowercased()]))
    }

    func testTheTwoBlocksAddUpAndTheServerNeverLiftsThePhones() throws {
        var list = AppGroupList<FakeSelection>()
        let games = try XCTUnwrap(list.add(label: "Games", selection: FakeSelection(apps: ["g"]), blocked: true))
        let video = try XCTUnwrap(list.add(label: "Video", selection: FakeSelection(apps: ["v"]), blocked: false))
        XCTAssertEqual(list.blockedSelections(alsoBlocked: []), [FakeSelection(apps: ["g"])], "the phone's block holds")
        XCTAssertEqual(list.blockedSelections(alsoBlocked: [video.lowercased()]),
                       [FakeSelection(apps: ["g"]), FakeSelection(apps: ["v"])])
        XCTAssertFalse(list.isBlockedByParentApp(id: games, serverBlocked: [video.lowercased()]))
        XCTAssertEqual(list.blockedSelections(alsoBlocked: ["not-a-group-here"]), [FakeSelection(apps: ["g"])],
                       "a rule for a group this phone does not have blocks nothing")
    }

    // MARK: - Saved for the extensions

    func testTheGroupsSurviveARelaunch() throws {
        let store = AppGroupStore<FakeSelection>(defaults: defaults)
        var list = AppGroupList<FakeSelection>()
        let id = try XCTUnwrap(list.add(label: "Games", selection: FakeSelection(apps: ["calc"]), blocked: true))
        XCTAssertTrue(store.save(list))
        let loaded = AppGroupStore<FakeSelection>(defaults: defaults).load()
        XCTAssertEqual(loaded.groups.map(\.id), [id])
        XCTAssertEqual(loaded.groups.first?.label, "Games")
        XCTAssertEqual(loaded.blockedSelections, [FakeSelection(apps: ["calc"])])
    }

    func testAFreshInstallHasNoGroups() {
        // A reinstall empties the app group container, so the phone starts with none.
        XCTAssertTrue(AppGroupStore<FakeSelection>(defaults: defaults).load().groups.isEmpty)
        defaults.set(Data("not a plist".utf8), forKey: AppGroupStore<FakeSelection>.key)
        XCTAssertTrue(AppGroupStore<FakeSelection>(defaults: defaults).load().groups.isEmpty, "unreadable reads as none")
    }

    // MARK: - What the capability report may say (an unreadable store must not erase the parent's groups)

    func testNoSavedGroupsIsAnEmptyListForTheReport() throws {
        let list = try XCTUnwrap(AppGroupStore<FakeSelection>(defaults: defaults).loadIfReadable(),
                                 "an absent key means truly no groups")
        XCTAssertTrue(list.groups.isEmpty)
    }

    func testAnAppGroupThatCannotBeOpenedIsNilForTheReport() {
        XCTAssertNil(AppGroupStore<FakeSelection>(defaults: nil).loadIfReadable())
        XCTAssertTrue(AppGroupStore<FakeSelection>(defaults: nil).load().groups.isEmpty, "the screen still shows none")
    }

    func testGroupsThatDoNotDecodeAreNilForTheReport() {
        defaults.set(Data("not a plist".utf8), forKey: AppGroupStore<FakeSelection>.key)
        XCTAssertNil(AppGroupStore<FakeSelection>(defaults: defaults).loadIfReadable())
        defaults.set("a string, not data", forKey: AppGroupStore<FakeSelection>.key)
        XCTAssertNil(AppGroupStore<FakeSelection>(defaults: defaults).loadIfReadable(), "a value of the wrong type")
    }

    func testSavedGroupsAreReadForTheReport() throws {
        let store = AppGroupStore<FakeSelection>(defaults: defaults)
        var list = AppGroupList<FakeSelection>()
        let id = try XCTUnwrap(list.add(label: "Games", selection: FakeSelection(apps: ["calc"])))
        XCTAssertTrue(store.save(list))
        XCTAssertEqual(store.loadIfReadable()?.groups.map(\.id), [id])
    }
}
