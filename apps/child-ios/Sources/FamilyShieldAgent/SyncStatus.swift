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
    /// times ("2 minutes ago", "45 minutes"), so they are already in the phone's language.
    public static func text(_ state: State, now: Date, locale: Locale = .current, language: String? = nil) -> String {
        func tr(_ key: String, _ arg: String? = nil) -> String {
            if let language { return arg.map { L10n.tr(key, language: language, $0) } ?? L10n.tr(key, language: language) }
            return arg.map { L10n.tr(key, $0) } ?? L10n.tr(key)
        }
        switch state {
        case .never:
            return tr("status_never_synced")
        case .fresh(let at):
            let relative = RelativeDateTimeFormatter()
            relative.locale = locale
            relative.unitsStyle = .full
            return tr("status_last_synced", relative.localizedString(for: min(at, now), relativeTo: now))
        case .stale(let at):
            let duration = DateComponentsFormatter()
            var calendar = Calendar(identifier: .gregorian)
            calendar.locale = locale
            duration.calendar = calendar
            duration.unitsStyle = .full
            duration.maximumUnitCount = 1
            duration.allowedUnits = [.day, .hour, .minute]
            let spoken = duration.string(from: max(0, now.timeIntervalSince(at))) ?? ""
            return tr("status_sync_stale", spoken)
        }
    }

    /// Whether a manual sync reached the server: a stored ruleset, or the server's own "consent withdrawn".
    public static func succeeded(_ outcome: RuleSyncer.Outcome) -> Bool {
        switch outcome {
        case .synced, .consentWithdrawn: return true
        case .notPaired, .failed: return false
        }
    }
}
