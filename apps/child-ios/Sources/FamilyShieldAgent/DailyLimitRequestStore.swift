import Foundation

/// U105, Codex's second finding: the "request sent" confirmation had no runtime path, because nothing ever
/// recorded that a request had been asked. This stores the **reset instant** the ask belongs to, so the next
/// shield configuration can show the confirmation — and so it stops applying when the day turns over.
///
/// Portable on purpose: the decision it feeds lives in `ShieldText.resolve`, which the macOS tests run.
public enum DailyLimitRequestStore {
    private static let key = "u105.dailyLimitRequestResetsAt"

    private static var defaults: UserDefaults? { UserDefaults(suiteName: AgentIdentityStore.suiteName) }

    /// Record an accepted ask against the day that resets at `resetsAt`.
    public static func record(resetsAt: Date) {
        defaults?.set(resetsAt.timeIntervalSince1970, forKey: key)
    }

    /// The reset instant a recorded ask belongs to, if any.
    public static func recordedResetsAt() -> Date? {
        guard let seconds = defaults?.object(forKey: key) as? Double else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// The record, but only when it belongs to `resetsAt` — the same day. A second of slack covers a
    /// recomputed midnight across a DST boundary.
    public static func recordedResetsAt(matching resetsAt: Date) -> Date? {
        guard let recorded = recordedResetsAt(),
              abs(recorded.timeIntervalSince(resetsAt)) < 1 else { return nil }
        return recorded
    }

    /// Drop a record whose day has already turned over, so yesterday's confirmation never shows today.
    public static func clearIfStale(now: Date = Date()) {
        guard let recorded = recordedResetsAt(), recorded <= now else { return }
        defaults?.removeObject(forKey: key)
    }

    /// Forget the record entirely. Used by tests and by a device that is unpaired.
    public static func clear() {
        defaults?.removeObject(forKey: key)
    }
}
