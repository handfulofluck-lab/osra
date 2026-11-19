import Foundation

/// #732: the language OSRA Kids runs in, shared through the app group so the shield extension can follow a system
/// language change. The main app records it at launch and whenever the locale changes; the shield reads it first
/// (`ShieldText.resolvedLanguage`). If the app has not run since a language switch, the shield keeps the language
/// it last recorded until the app next opens.
///
/// ADR-0042 D1a (#883): every catalog the build carries is compiled in, but a language is offered only when it is
/// in the family's **enabled list** — released languages for everyone, plus `beta` languages for tester families,
/// which the server sends in the rule-sync payload. A language outside the list falls back to the base language
/// (D4), so a phone set to French never shows a half-enabled screen before French is released.
public enum SharedLanguage {
    public static let key = "agent.uiLanguage"

    /// The enabled list, in the app group next to the language so both the app and the extensions read one value.
    public static let enabledKey = "agent.enabledLanguages"

    /// The compiled-in default: the released languages only. Changing this is a release decision, not a build one.
    public static let released = ["en", "ar"]

    /// The base language: the fallback for any language that is not enabled (D4).
    public static let base = "en"

    /// The shipped language for `preferences` (the app's own, which iOS refreshes when it relaunches the app).
    public static func language(for preferences: [String],
                                enabled: [String] = enabledLanguages()) -> String {
        Bundle.preferredLocalizations(from: normalised(enabled), forPreferences: preferences).first ?? base
    }

    /// The language the app should draw in: what it recorded for the current system preference when that is still
    /// enabled, otherwise the first enabled match, otherwise the base language.
    public static func current(enabled: [String] = enabledLanguages(),
                               stored: String? = stored(),
                               preferences: [String] = Locale.preferredLanguages) -> String {
        let allowed = normalised(enabled)
        if let stored, allowed.contains(stored) { return stored }
        return language(for: preferences, enabled: allowed)
    }

    /// Records the language for `preferences` in the app group.
    ///
    /// The enabled list is read from the **same** store this writes to: reading it from the app group while writing
    /// somewhere else made the two disagree, which is every test's seam and, in production, the difference between
    /// a family getting a `beta` language at the next sync and at the next launch.
    public static func record(_ preferences: [String] = Locale.preferredLanguages,
                              defaults: UserDefaults? = UserDefaults(suiteName: AgentIdentityStore.suiteName)) {
        defaults?.set(language(for: preferences, enabled: enabledLanguages(defaults: defaults)), forKey: key)
    }

    /// The last recorded language, if any.
    public static func stored(defaults: UserDefaults? = UserDefaults(suiteName: AgentIdentityStore.suiteName)) -> String? {
        defaults?.string(forKey: key)
    }

    /// The enabled languages for this family. Absent, empty or malformed means the compiled-in default, never an
    /// empty list: a family with no answered sync must still read English and Arabic.
    public static func enabledLanguages(defaults: UserDefaults? = UserDefaults(suiteName: AgentIdentityStore.suiteName))
        -> [String] {
        let stored = usable(defaults?.stringArray(forKey: enabledKey) ?? [])
        return normalised(stored.isEmpty ? released : stored)
    }

    /// Records the enabled list the server sent **and re-records the language**. An empty or blank list is not a
    /// list: it leaves the last one, because a server that has nothing to say must not drop a family back to
    /// English. The base language is always kept, so a payload that forgets it cannot leave the app with nothing to
    /// draw.
    ///
    /// The second write is the point of a **served** switch (D1a): `stored` wins over the system list, so a family
    /// whose `beta` language is switched on would otherwise keep the language recorded at launch until the app was
    /// next started cold.
    public static func setEnabled(_ languages: [String],
                                  preferences: [String] = Locale.preferredLanguages,
                                  defaults: UserDefaults? = UserDefaults(suiteName: AgentIdentityStore.suiteName)) {
        let list = usable(languages)
        guard !list.isEmpty else { return }
        defaults?.set(normalised(list), forKey: enabledKey)
        record(preferences, defaults: defaults)
    }

    /// Records only the list, without touching the recorded language.
    public static func recordEnabled(_ languages: [String],
                                     defaults: UserDefaults? = UserDefaults(suiteName: AgentIdentityStore.suiteName)) {
        let list = usable(languages)
        guard !list.isEmpty else { return }
        defaults?.set(normalised(list), forKey: enabledKey)
    }

    /// Trims, validates, drops duplicates, and guarantees the base language first. One list, one meaning, wherever
    /// it comes from: the compiled default, the app group, or the server.
    ///
    /// The list is **server-supplied** (ADR-0042 D1a), so a tag is kept only when it has the shape of a language tag
    /// — letters and digits joined by hyphens, a 2–3 letter primary subtag, no separators, no `..`, bounded length,
    /// and at most `maxEnabled` of them. Anything else is dropped exactly like a tag with no catalog: the base
    /// language is used, and the rest of the payload is still honoured. A tag is never allowed to reach a bundle
    /// lookup or the shared app group as free text.
    public static func normalised(_ languages: [String]) -> [String] {
        var seen = Set<String>()
        var rest: [String] = []
        for tag in usable(languages) {
            guard tag != base, seen.insert(tag).inserted else { continue }
            rest.append(tag)
        }
        return [base] + rest.prefix(maxEnabled - 1)
    }

    /// How many languages one family may have: the build carries seven, so the rest is slack for a newer server.
    /// A payload beyond this is truncated, never rejected wholesale.
    public static let maxEnabled = 16

    /// The tags that say something: trimmed, non-empty and shaped like a language tag. Everything else is the same
    /// as not sent.
    private static func usable(_ languages: [String]) -> [String] {
        languages
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { isLanguageTag($0) }
    }

    /// `en`, `ar`, `fr`, `pt-BR`, `zh-Hant-TW`: 2–3 letters, then hyphen-separated alphanumeric subtags of 1–8.
    /// Deliberately ASCII only: a tag is a lookup key for a directory name, not display text.
    static func isLanguageTag(_ tag: String) -> Bool {
        guard (2...35).contains(tag.count) else { return false }
        let parts = tag.split(separator: "-", omittingEmptySubsequences: false)
        guard let first = parts.first, (2...3).contains(first.count),
              first.allSatisfy({ $0.isASCII && $0.isLetter }) else { return false }
        return parts.dropFirst().allSatisfy { part in
            (1...8).contains(part.count) && part.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
        }
    }
}
