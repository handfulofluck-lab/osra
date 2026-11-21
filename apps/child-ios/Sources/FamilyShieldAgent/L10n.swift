import Foundation

/// The app's own text (5.5, Arabic Language Bureau): every line a family reads comes from the package's
/// `Localizable.strings` / `.stringsdict` (English and Arabic), never from a literal in a view. The Arabic is
/// the Bureau's, approved by Karim; nobody writes Arabic anywhere else.
///
/// ADR-0042 D1a (#883): the table is chosen from the family's **enabled list** (`SharedLanguage`), not from the
/// bundle's preferred localization. A build that carries `fr.lproj` must still draw English on a phone whose
/// system language is French until French is enabled, so the lookup goes through the enabled language's bundle
/// rather than `Bundle.module.localizedString`.
public enum L10n {
    /// The line for `key` in the language the app runs in (`SharedLanguage.current`).
    public static func tr(_ key: String) -> String {
        tr(key, language: SharedLanguage.current())
    }

    /// A line with `%d`/`%@` arguments, plural forms included (`.stringsdict`).
    public static func tr(_ key: String, _ args: CVarArg...) -> String {
        String(format: tr(key), locale: Locale.current, arguments: args)
    }

    /// The line for `key` in one language, for the tests (and the extensions, which read the phone's language).
    public static func tr(_ key: String, language: String, _ args: CVarArg...) -> String {
        let bundle = bundle(for: language)
        let format = bundle.localizedString(forKey: key, value: nil, table: nil)
        return args.isEmpty ? format : String(format: format, locale: Locale(identifier: language), arguments: args)
    }

    /// The package's table for one language, the base language when the build does not carry that language.
    ///
    /// Never `Bundle.module` itself: its own localization is chosen by the **system** language, so an enabled tag
    /// with no catalog of its own (a newer server, a typo) would hand the app's text back to the phone while the
    /// shield drew English (D4).
    public static func bundle(for language: String) -> Bundle {
        if let table = Bundle.module.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:)) {
            return table
        }
        if language == SharedLanguage.base { return Bundle.module }
        return Bundle.module.path(forResource: SharedLanguage.base, ofType: "lproj").flatMap(Bundle.init(path:))
            ?? Bundle.module
    }
}
