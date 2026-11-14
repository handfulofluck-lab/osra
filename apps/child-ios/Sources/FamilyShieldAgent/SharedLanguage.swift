import Foundation

/// #732: the language OSRA Kids runs in, shared through the app group so the shield extension can follow a system
/// language change. The main app records it at launch and whenever the locale changes; the shield reads it first
/// (`ShieldText.resolvedLanguage`). If the app has not run since a language switch, the shield keeps the language
/// it last recorded until the app next opens.
public enum SharedLanguage {
    public static let key = "agent.uiLanguage"

    /// The shipped language for `preferences` (the app's own, which iOS refreshes when it relaunches the app).
    public static func language(for preferences: [String]) -> String {
        Bundle.preferredLocalizations(from: ["en", "ar"], forPreferences: preferences).first ?? "en"
    }

    /// Records the language for `preferences` in the app group.
    public static func record(_ preferences: [String] = Locale.preferredLanguages,
                              defaults: UserDefaults? = UserDefaults(suiteName: AgentIdentityStore.suiteName)) {
        defaults?.set(language(for: preferences), forKey: key)
    }

    /// The last recorded language, if any.
    public static func stored(defaults: UserDefaults? = UserDefaults(suiteName: AgentIdentityStore.suiteName)) -> String? {
        defaults?.string(forKey: key)
    }
}
