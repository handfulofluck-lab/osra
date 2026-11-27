import Foundation

/// U105, Codex's first finding: the shield's **text** and its **tap** must come from the same cause.
///
/// The action delegate is handed an opaque `ApplicationToken` and never learns the bundle identifier, so it cannot
/// resolve the cause itself. The configuration side can. This records what was resolved when the shield was drawn,
/// so the tap follows the cause the child actually saw — a shield reading "Blocked by Bedtime" sends an access
/// request even if the daily limit is also spent.
///
/// A tap always follows the configuration that drew the shield it was pressed on, so "last drawn" is the right key.
public enum ShieldCauseStore {
    private static let dailyKey = "u105.shieldCauseDailyLimit"
    private static let resetsKey = "u105.shieldCauseResetsAt"

    private static var defaults: UserDefaults? { UserDefaults(suiteName: AgentIdentityStore.suiteName) }

    /// Called by the configuration data source with the situation it resolved.
    public static func record(_ situation: ShieldText.Situation) {
        switch situation {
        case .dailyLimit(let resetsAt), .dailyLimitRequestSent(let resetsAt):
            defaults?.set(true, forKey: dailyKey)
            defaults?.set(resetsAt.timeIntervalSince1970, forKey: resetsKey)
        case .window:
            defaults?.set(false, forKey: dailyKey)
            defaults?.removeObject(forKey: resetsKey)
        }
    }

    /// True when the shield the child is looking at was drawn for the daily limit rather than a window.
    public static var lastDrawnWasDailyLimit: Bool { defaults?.bool(forKey: dailyKey) ?? false }

    /// The reset instant of that shield, when it was the daily limit.
    public static var lastDrawnResetsAt: Date? {
        guard let seconds = defaults?.object(forKey: resetsKey) as? Double else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}
