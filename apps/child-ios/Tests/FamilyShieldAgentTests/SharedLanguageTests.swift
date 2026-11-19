import XCTest
@testable import FamilyShieldAgent

/// ADR-0042 D1a (#883): every catalog the build carries is compiled in, but a language is offered only when it
/// is in the family's enabled list. These rows pin the list itself: where it comes from, what a bad value means,
/// and that a language outside it falls back to the base language rather than to a half-enabled screen.
final class SharedLanguageTests: XCTestCase {

    private let suite = UserDefaults(suiteName: "com.osratech.child.tests.sharedLanguage")!

    override func setUp() {
        super.setUp()
        suite.removePersistentDomain(forName: "com.osratech.child.tests.sharedLanguage")
    }

    override func tearDown() {
        suite.removePersistentDomain(forName: "com.osratech.child.tests.sharedLanguage")
        super.tearDown()
    }

    // MARK: - The list

    /// The compiled-in default is the released pair: a family whose sync has not answered yet offers en and ar.
    func testDefaultIsTheReleasedPair() {
        XCTAssertEqual(SharedLanguage.released, ["en", "ar"])
        XCTAssertEqual(SharedLanguage.enabledLanguages(defaults: suite), ["en", "ar"])
    }

    /// An empty or blank list is the same as no list: the app never ends up with nothing to draw, and a server that
    /// stops sending the field cannot drop a family back to English.
    func testAnEmptyOrBlankListFallsBackToReleased() {
        SharedLanguage.recordEnabled([], defaults: suite)
        XCTAssertEqual(SharedLanguage.enabledLanguages(defaults: suite), ["en", "ar"])

        SharedLanguage.recordEnabled(["", "   "], defaults: suite)
        XCTAssertEqual(SharedLanguage.enabledLanguages(defaults: suite), ["en", "ar"])
    }

    func testABlankListLeavesTheLastOneInPlace() {
        SharedLanguage.recordEnabled(["en", "ar", "fr"], defaults: suite)
        SharedLanguage.recordEnabled([], defaults: suite)
        SharedLanguage.recordEnabled([" "], defaults: suite)
        XCTAssertEqual(SharedLanguage.enabledLanguages(defaults: suite), ["en", "ar", "fr"])
    }

    /// The base language is always present, first, and never repeated; order is otherwise the server's.
    func testBaseLanguageIsAlwaysPresentFirstAndOnce() {
        XCTAssertEqual(SharedLanguage.normalised(["ar", "fr", "fr"]), ["en", "ar", "fr"])
        XCTAssertEqual(SharedLanguage.normalised(["fr", "en", " "]), ["en", "fr"])
    }

    func testTheRecordedListIsWhatTheFamilyReads() {
        SharedLanguage.recordEnabled(["en", "ar", "fr"], defaults: suite)
        XCTAssertEqual(SharedLanguage.enabledLanguages(defaults: suite), ["en", "ar", "fr"])
    }

    // MARK: - Which language a phone draws in

    /// The row D1a exists for: a phone set to French draws English while French is not enabled, so a catalog
    /// that happens to be compiled in cannot show itself early.
    func testAFrenchPhoneDrawsEnglishWhileFrenchIsNotEnabled() {
        XCTAssertEqual(SharedLanguage.current(enabled: ["en", "ar"], stored: nil, preferences: ["fr-FR", "fr"]), "en")
    }

    func testAnEnabledLanguageIsUsed() {
        XCTAssertEqual(SharedLanguage.current(enabled: ["en", "ar", "fr"], stored: nil,
                                              preferences: ["fr-FR", "en"]), "fr")
        XCTAssertEqual(SharedLanguage.current(enabled: ["en", "ar"], stored: nil,
                                              preferences: ["ar-AE", "en"]), "ar")
    }

    /// #732, kept: the language the app recorded wins over the system list, because the shield extension reads it
    /// after a system change. It still has to be enabled.
    func testARecordedLanguageInsideTheListIsKept() {
        XCTAssertEqual(SharedLanguage.current(enabled: ["en", "ar"], stored: "ar", preferences: ["en"]), "ar")
    }

    /// A recorded language the family may no longer use is refused, not shown: a tester family that loses its
    /// `beta` flag goes back to English at the next sync.
    func testARecordedLanguageOutsideTheListIsRefused() {
        XCTAssertEqual(SharedLanguage.current(enabled: ["en", "ar"], stored: "fr", preferences: ["fr-FR"]), "en")
    }

    // MARK: - The shield

    /// The block screen makes the same decision as the app, from the same list: an extension that kept its own
    /// idea of "en and ar" would draw French on a phone the app drew in English.
    func testTheShieldUsesTheEnabledListForTheSystemPreference() {
        XCTAssertEqual(ShieldText.preferredLanguage(preferences: { ["fr-FR"] }, enabled: { ["en", "ar"] }), "en")
        XCTAssertEqual(ShieldText.preferredLanguage(preferences: { ["fr-FR"] }, enabled: { ["en", "ar", "fr"] }), "fr")
    }

    func testTheShieldKeepsARecordedEnabledLanguageAndRefusesAStranger() {
        XCTAssertEqual(ShieldText.resolvedLanguage(stored: "ar", enabled: ["en", "ar"], fallback: { "en" }), "ar")
        XCTAssertEqual(ShieldText.resolvedLanguage(stored: "fr", enabled: ["en", "ar"], fallback: { "en" }), "en")
    }

    // MARK: - The served switch takes effect without a relaunch

    /// D1a is a **served** switch: when the rules turn `beta` on for a family, the app must start drawing that
    /// language at the next sync. `stored` wins over the system list, so writing the list alone left the family on
    /// the language recorded at launch until the app was next started cold.
    func testANewlyEnabledLanguageTakesEffectAtTheNextSync() {
        SharedLanguage.recordEnabled(["en", "ar"], defaults: suite)
        SharedLanguage.record(["en-US"], defaults: suite)
        XCTAssertEqual(SharedLanguage.current(enabled: SharedLanguage.enabledLanguages(defaults: suite),
                                              stored: SharedLanguage.stored(defaults: suite),
                                              preferences: ["fr-FR", "en"]), "en", "before the switch widens")

        SharedLanguage.setEnabled(["en", "ar", "fr"], preferences: ["fr-FR", "en"], defaults: suite)
        XCTAssertEqual(SharedLanguage.stored(defaults: suite), "fr", "the newly enabled language is recorded")
        XCTAssertEqual(SharedLanguage.current(enabled: SharedLanguage.enabledLanguages(defaults: suite),
                                              stored: SharedLanguage.stored(defaults: suite),
                                              preferences: ["fr-FR", "en"]), "fr")
    }

    /// D4: an enabled tag the build has no catalog for (a newer server, a typo) draws the base language — not the
    /// phone's, which is what `Bundle.module` on its own would give.
    func testAnEnabledTagWithNoCatalogDrawsTheBaseLanguage() {
        let table = L10n.bundle(for: "de")
        XCTAssertEqual(table.localizedString(forKey: "block_title_blocked", value: nil, table: nil),
                       L10n.tr("block_title_blocked", language: "en"))
    }

    /// The fallback must be the base **table**, not `Bundle.module`: on an English runner both give the same string,
    /// so the row compares the two bundles by path, which is the only way D4's failure mode can go red here.
    func testTheMissingTableFallbackIsTheBaseBundleNotThePackageBundle() {
        XCTAssertEqual(L10n.bundle(for: "de").bundlePath, L10n.bundle(for: SharedLanguage.base).bundlePath)
        XCTAssertNotEqual(L10n.bundle(for: "de").bundlePath, Bundle.module.bundlePath)
    }

    // MARK: - The list is server-supplied, so a tag is validated

    /// A payload is not trusted text: only a tag shaped like a language tag is kept, and the rest of the list is
    /// still honoured. Before this, any string reached the app group and a bundle lookup.
    func testOnlyTagsShapedLikeLanguageTagsAreKept() {
        XCTAssertEqual(SharedLanguage.normalised(["../evil", "fr/../..", "/etc/passwd", "", "  ", "fr"]),
                       ["en", "fr"])
        XCTAssertEqual(SharedLanguage.normalised(["FR"]), ["en", "FR"], "case is the caller's, not ours to rewrite")
        XCTAssertEqual(SharedLanguage.normalised(["pt-BR", "zh-Hant-TW"]), ["en", "pt-BR", "zh-Hant-TW"])
        XCTAssertFalse(SharedLanguage.isLanguageTag(String(repeating: "a", count: 200)))
    }

    func testTheListIsBoundedSoAPayloadCannotGrowItWithoutLimit() {
        let many = (0..<40).map { "l\($0)" }
        XCTAssertEqual(SharedLanguage.normalised(many).count, SharedLanguage.maxEnabled)
    }

    /// Unpairing hands the phone to nobody: the served list and the language it recorded belonged to the family that
    /// paired, and a leftover `beta` language would follow the next family until its first sync.
    func testUnpairingForgetsTheLanguageState() {
        let shared = UserDefaults(suiteName: AgentIdentityStore.suiteName)!
        let hadList = shared.stringArray(forKey: SharedLanguage.enabledKey)
        let hadLanguage = shared.string(forKey: SharedLanguage.key)
        defer {
            if let hadList { shared.set(hadList, forKey: SharedLanguage.enabledKey) }
            else { shared.removeObject(forKey: SharedLanguage.enabledKey) }
            if let hadLanguage { shared.set(hadLanguage, forKey: SharedLanguage.key) }
            else { shared.removeObject(forKey: SharedLanguage.key) }
        }
        SharedLanguage.setEnabled(["en", "ar", "fr"], preferences: ["fr-FR"], defaults: shared)
        XCTAssertEqual(SharedLanguage.stored(defaults: shared), "fr")

        AgentIdentityStore.clear()

        XCTAssertNil(shared.stringArray(forKey: SharedLanguage.enabledKey))
        XCTAssertNil(shared.string(forKey: SharedLanguage.key))
    }

    /// The point of shipping five catalogs: a beta language must actually draw its own text through the code path the
    /// app renders with. Every other positive row was `en`/`ar`, so returning the base table for anything else would
    /// have stayed green.
    func testAnEnabledBetaLanguageDrawsItsOwnText() {
        let shared = UserDefaults(suiteName: AgentIdentityStore.suiteName)!
        let hadList = shared.stringArray(forKey: SharedLanguage.enabledKey)
        let hadLanguage = shared.string(forKey: SharedLanguage.key)
        defer {
            if let hadList { shared.set(hadList, forKey: SharedLanguage.enabledKey) }
            else { shared.removeObject(forKey: SharedLanguage.enabledKey) }
            if let hadLanguage { shared.set(hadLanguage, forKey: SharedLanguage.key) }
            else { shared.removeObject(forKey: SharedLanguage.key) }
        }
        SharedLanguage.setEnabled(["en", "ar", "fr"], preferences: ["fr-FR", "en"], defaults: shared)

        let french = L10n.tr("block_title_blocked", language: "fr")
        XCTAssertNotEqual(french, L10n.tr("block_title_blocked", language: "en"))
        XCTAssertEqual(L10n.tr("block_title_blocked"), french, "the app draws the enabled language's own table")
    }

    /// And the block screen, which runs in another process with its own lookup: a beta language must reach it too, or
    /// a tester family sees one language in the app and English behind the shield — the half-enabled screen D1a
    /// forbids.
    func testTheShieldDrawsABetaLanguageToo() {
        let french = ShieldText.make(window: nil, language: "fr").title
        XCTAssertEqual(french, L10n.tr("block_title_blocked", language: "fr"))
        XCTAssertNotEqual(french, ShieldText.make(window: nil, language: "en").title)
    }
}

/// ADR-0042 D1a (#883), the wiring: `L10n.tr` must draw in the language the **enabled list** allows, not in the
/// bundle's preferred localization. These rows use the real app group the app and the shield extensions share, the
/// same suite `SharedLanguage` reads (`RuleSyncTests` writes it the same way).
final class AppGroupLanguageTests: XCTestCase {

    private let defaults = UserDefaults(suiteName: AgentIdentityStore.suiteName)!
    private var hadLanguage: String?
    private var hadEnabled: [String]?

    override func setUp() {
        super.setUp()
        hadLanguage = defaults.string(forKey: SharedLanguage.key)
        hadEnabled = defaults.stringArray(forKey: SharedLanguage.enabledKey)
    }

    override func tearDown() {
        if let hadLanguage {
            defaults.set(hadLanguage, forKey: SharedLanguage.key)
        } else {
            defaults.removeObject(forKey: SharedLanguage.key)
        }
        if let hadEnabled {
            defaults.set(hadEnabled, forKey: SharedLanguage.enabledKey)
        } else {
            defaults.removeObject(forKey: SharedLanguage.enabledKey)
        }
        super.tearDown()
    }

    /// The two tables really do differ, so the rows below cannot pass by accident.
    func testTheEnglishAndArabicTablesDiffer() {
        XCTAssertNotEqual(L10n.tr("block_title_blocked", language: "en"), L10n.tr("block_title_blocked", language: "ar"))
    }

    /// The language the app recorded decides the line. Before this change `L10n.tr` followed the bundle's preferred
    /// localization, which is the simulator's English on this runner, so this row was red.
    func testTheAppDrawsTheRecordedLanguageNotTheSystemOne() {
        SharedLanguage.recordEnabled(["en", "ar"], defaults: defaults)
        defaults.set("ar", forKey: SharedLanguage.key)
        XCTAssertEqual(L10n.tr("block_title_blocked"), L10n.tr("block_title_blocked", language: "ar"))
    }

    /// A recorded language outside the enabled list draws English (D4), even when its code is still in the app group
    /// from an earlier build or an earlier `beta` flag.
    func testALanguageOutsideTheEnabledListDrawsEnglish() {
        SharedLanguage.recordEnabled(["en", "ar"], defaults: defaults)
        defaults.set("fr", forKey: SharedLanguage.key)
        XCTAssertEqual(L10n.tr("block_title_blocked"), L10n.tr("block_title_blocked", language: "en"))
    }
}
