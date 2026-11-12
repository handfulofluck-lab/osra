import Foundation

/// The app's own text (5.5, Arabic Language Bureau): every line a family reads comes from the package's
/// `Localizable.strings` / `.stringsdict` (English and Arabic), never from a literal in a view. The Arabic is
/// the Bureau's, approved by Karim; nobody writes Arabic anywhere else.
public enum L10n {
    /// The line for `key` in the phone's language (the package's tables, English when the language is missing).
    public static func tr(_ key: String) -> String {
        Bundle.module.localizedString(forKey: key, value: nil, table: nil)
    }

    /// A line with `%d`/`%@` arguments, plural forms included (`.stringsdict`).
    public static func tr(_ key: String, _ args: CVarArg...) -> String {
        String(format: tr(key), locale: Locale.current, arguments: args)
    }

    /// The line for `key` in one language, for the tests (and the extensions, which read the phone's language).
    public static func tr(_ key: String, language: String, _ args: CVarArg...) -> String {
        let bundle = Bundle.module.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:)) ?? Bundle.module
        let format = bundle.localizedString(forKey: key, value: nil, table: nil)
        return args.isEmpty ? format : String(format: format, locale: Locale(identifier: language), arguments: args)
    }
}
