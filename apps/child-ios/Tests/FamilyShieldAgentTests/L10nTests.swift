import XCTest
@testable import FamilyShieldAgent

/// 5.5, Arabic Language Bureau: OSRA Kids' own screens read from the package's tables. Every key exists in English
/// and Arabic, every key the code asks for exists, and the Arabic plural and formatted lines come out as the Bureau
/// wrote them (Karim approved the set on 12 Nov, 11:20Z).
final class L10nTests: XCTestCase {

    private func table(_ language: String) throws -> [String: String] {
        let path = try XCTUnwrap(Bundle.module.path(forResource: "Localizable", ofType: "strings",
                                                    inDirectory: nil, forLocalization: language),
                                 "no \(language) Localizable.strings in the package bundle")
        return try XCTUnwrap(NSDictionary(contentsOfFile: path) as? [String: String])
    }

    func testEnglishAndArabicHaveTheSameKeysAndNoEmptyLine() throws {
        let en = try table("en"), ar = try table("ar")
        XCTAssertEqual(Set(en.keys), Set(ar.keys), "a key in one language only")
        XCTAssertTrue(ar.values.allSatisfy { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
        XCTAssertGreaterThanOrEqual(en.count, 80)
    }

    /// ADR-0042 (#883): the five launch languages carry every English line with the same placeholders, and no empty
    /// value. A line missing here would draw its key on the screen instead of a sentence, so this is the gate that
    /// lets the catalogs land behind the D1a switch.
    func testTheFiveLaunchLanguagesCoverEnglishAndKeepItsPlaceholders() throws {
        let en = try table("en")
        for language in ["tr", "id", "ms", "fr", "ur"] {
            let other = try table(language)
            let missing = Set(en.keys).subtracting(other.keys).sorted()
            XCTAssertTrue(missing.isEmpty, "\(language) is missing \(missing)")
            XCTAssertTrue(other.values.allSatisfy { !$0.trimmingCharacters(in: .whitespaces).isEmpty },
                          "\(language) has an empty line")
            for (key, english) in en {
                guard let line = other[key] else { continue }
                XCTAssertEqual(Self.placeholders(english), Self.placeholders(line),
                               "\(language) changes the placeholders of \(key)")
            }
        }
    }

    /// A catalog may run ahead of English while a screen is still held (the `#880` and `#881` lines), so extra keys
    /// are allowed. The plurals are not: the same two keys, in every language that ships one.
    func testTheFiveLaunchLanguagesKeepTheEnglishPlurals() throws {
        let en = try pluralKeys("en")
        for language in ["tr", "id", "ms", "fr", "ur"] {
            XCTAssertEqual(try pluralKeys(language), en, "\(language) plurals")
        }
    }

    private func pluralKeys(_ language: String) throws -> Set<String> {
        let path = try XCTUnwrap(Bundle.module.path(forResource: "Localizable", ofType: "stringsdict",
                                                    inDirectory: nil, forLocalization: language),
                                 "no \(language) Localizable.stringsdict in the package bundle")
        let plist = try XCTUnwrap(NSDictionary(contentsOfFile: path) as? [String: Any])
        return Set(plist.keys.compactMap { $0 as? String })
    }

    private static func placeholders(_ line: String) -> [String] {
        let pattern = try? NSRegularExpression(pattern: #"%(?:\d+\$)?[@difs]"#)
        let matches = pattern?.matches(in: line, range: NSRange(line.startIndex..., in: line)) ?? []
        return matches.compactMap { Range($0.range, in: line).map { String(line[$0]) } }.sorted()
    }

    func testEveryKeyTheCodeAsksForExists() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FamilyShieldAgent")
        let files = try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        let pattern = try NSRegularExpression(pattern: #"L10n\.tr\("([a-z_]+)""#)
        var used = Set<String>()
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for m in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                used.insert(String(text[Range(m.range(at: 1), in: text)!]))
            }
        }
        XCTAssertGreaterThanOrEqual(used.count, 70, "the views read their text through L10n")
        let en = try table("en"), ar = try table("ar")
        let plurals: Set<String> = ["pin_wrong", "pin_locked"]
        for key in used.subtracting(plurals) {
            XCTAssertNotNil(en[key], "en has no \(key)")
            XCTAssertNotNil(ar[key], "ar has no \(key)")
        }
    }

    func testTheArabicPluralsFollowTheBureauForms() {
        XCTAssertEqual(L10n.tr("pin_wrong", language: "ar", 1), "رمز PIN غير صحيح. بقيت محاولة واحدة قبل الإيقاف المؤقت.")
        XCTAssertEqual(L10n.tr("pin_wrong", language: "ar", 2), "رمز PIN غير صحيح. بقيت محاولتان قبل الإيقاف المؤقت.")
        XCTAssertEqual(L10n.tr("pin_wrong", language: "ar", 3), "رمز PIN غير صحيح. بقيت 3 محاولات قبل الإيقاف المؤقت.")
        XCTAssertEqual(L10n.tr("pin_locked", language: "ar", 1), "محاولات خاطئة كثيرة. حاول مرة أخرى بعد ثانية واحدة.")
        XCTAssertEqual(L10n.tr("pin_locked", language: "ar", 2), "محاولات خاطئة كثيرة. حاول مرة أخرى بعد ثانيتين.")
        XCTAssertEqual(L10n.tr("pin_locked", language: "ar", 5), "محاولات خاطئة كثيرة. حاول مرة أخرى بعد 5 ثوانٍ.")
        XCTAssertEqual(L10n.tr("pin_locked", language: "ar", 30), "محاولات خاطئة كثيرة. حاول مرة أخرى بعد 30 ثانية.")
        XCTAssertEqual(L10n.tr("pin_wrong", language: "en", 1), "Wrong PIN. 1 try left before a pause.")
        XCTAssertEqual(L10n.tr("pin_wrong", language: "en", 4), "Wrong PIN. 4 tries left before a pause.")
    }

    func testFormattedAndChangedLines() {
        XCTAssertEqual(L10n.tr("groups_counts", language: "ar", 5, 1, 2), "التطبيقات: 5 · الفئات: 1 · المواقع: 2")
        XCTAssertEqual(L10n.tr("pair_error_http", language: "ar", 403), "رفض الخادم الطلب (HTTP 403).")
        // An Arabic format isolates each %@ argument (U+2068 … U+2069), as the block screen expects (ShieldTextTests).
        XCTAssertEqual(L10n.tr("block_window_line", language: "ar", "Bedtime", "07:00"),
                       "محجوب بواسطة \u{2068}Bedtime\u{2069} حتى \u{2068}07:00\u{2069}")
        XCTAssertEqual(L10n.tr("pair_section_title", language: "en"), "OSRA Kids", "not OSRA Child Agent")
        XCTAssertFalse(L10n.tr("pair_error_save", language: "en").contains("app group"), "no developer sentence for a family")
    }
}
