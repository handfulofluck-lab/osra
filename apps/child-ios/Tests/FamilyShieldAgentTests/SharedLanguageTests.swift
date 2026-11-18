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
