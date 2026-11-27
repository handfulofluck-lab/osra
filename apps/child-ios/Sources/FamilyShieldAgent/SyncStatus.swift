import Foundation

/// #602 items 3 and 4: what the status screen says about the last sync. "Paired" alone could not tell anyone
/// that the server had not been reached for hours; now the screen shows when it last synced, and turns amber
/// after `staleAfter`. Pure, with the clock and locale passed in.
public enum SyncStatus {
    /// Past this, the screen warns: a phone in use syncs on every open and on each push.
    public static let staleAfter: TimeInterval = 30 * 60

    public enum State: Equatable {
        case never
        case fresh(Date)
        case stale(Date)
    }

    public static func state(syncedAt: Date?, now: Date) -> State {
        guard let syncedAt else { return .never }
        return now.timeIntervalSince(syncedAt) > staleAfter ? .stale(syncedAt) : .fresh(syncedAt)
    }

    /// The line under "Paired", in `language` when given (tests), else the phone's language. iOS words the
    /// times ("2 minutes ago", "2 days ago"), so they are already in the phone's language.
    public static func text(_ state: State, now: Date, locale: Locale = .current, language: String? = nil) -> String {
        func tr(_ key: String, _ arg: String? = nil) -> String {
            if let language { return arg.map { L10n.tr(key, language: language, $0) } ?? L10n.tr(key, language: language) }
            return arg.map { L10n.tr(key, $0) } ?? L10n.tr(key)
        }
        switch state {
        case .never:
            return tr("status_never_synced")
        case .fresh(let at):
            if now.timeIntervalSince(at) < justNow { return tr("status_last_synced_now") }
            return tr("status_last_synced", relative(at, now: now, locale: locale))
        case .stale(let at):
            return tr("status_sync_stale", relative(at, now: now, locale: locale))
        }
    }

    /// Under a minute the screen says "just now": the formatter would give "in 0 seconds" or a seconds count.
    public static let justNow: TimeInterval = 60

    /// "5 minutes ago", "2 days ago", in the phone's language with Western digits (R9). Both lines use it, so
    /// the Arabic noun takes the case iOS gives it after "ago" (Bureau, row 5.7).
    static func relative(_ at: Date, now: Date, locale: Locale) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = L10n.latinDigits(locale)
        formatter.unitsStyle = .full
        return formatter.localizedString(for: min(at, now), relativeTo: now)
    }

    /// Whether a manual sync reached the server: a stored ruleset, or the server's own "consent withdrawn".
    public static func succeeded(_ outcome: RuleSyncer.Outcome) -> Bool {
        switch outcome {
        case .synced, .consentWithdrawn: return true
        case .notPaired, .failed: return false
        }
    }
}
