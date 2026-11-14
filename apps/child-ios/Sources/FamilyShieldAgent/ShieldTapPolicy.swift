import Foundation

/// #602 item 1: what a tap on the OSRA shield does. "Request access" tells the parent (an `app_blocked` alert);
/// "Exit to Home screen" closes the blocked app and tells nobody, because a child leaving a blocked app is the block
/// working, not news. It is only counted, in the app group, for telemetry. Pure, so the tests need no
/// ManagedSettings.
public enum ShieldTapPolicy {
    public enum Tap: Equatable { case requestAccess, exitHome, other }

    public struct Outcome: Equatable {
        /// Whether the parent gets an alert.
        public let alertsParent: Bool
        /// Whether the shield closes the blocked app.
        public let closesApp: Bool
        /// Whether the tap is added to the local dismissal count.
        public let countsDismissal: Bool
    }

    public static func outcome(_ tap: Tap) -> Outcome {
        switch tap {
        case .requestAccess: return Outcome(alertsParent: true, closesApp: false, countsDismissal: false)
        case .exitHome: return Outcome(alertsParent: false, closesApp: true, countsDismissal: true)
        case .other: return Outcome(alertsParent: false, closesApp: false, countsDismissal: false)
        }
    }

    /// #744: one access request per blocked app, website or category every `requestWindow`. Repeated taps on
    /// "Request access" inside the window send nothing, so a child cannot flood the parent's phone and bury the
    /// real request; the shield stays up either way.
    public static let requestWindow: TimeInterval = 5 * 60
    public static let requestTimesKey = "shield.requestTimes"

    /// Whether this tap on "Request access" for `target` should alert the parent, recording it when it does.
    /// With no app group it sends, so a request is never lost to a storage problem.
    public static func shouldSendRequest(target: String, now: Date = Date(), defaults: UserDefaults?) -> Bool {
        guard let defaults else { return true }
        let nowSeconds = now.timeIntervalSince1970
        var times = (defaults.dictionary(forKey: requestTimesKey) as? [String: Double] ?? [:])
            .filter { nowSeconds - $0.value < requestWindow && $0.value <= nowSeconds }
        if times[target] != nil {
            defaults.set(times, forKey: requestTimesKey)
            return false
        }
        times[target] = nowSeconds
        defaults.set(times, forKey: requestTimesKey)
        return true
    }

    /// The app-group key of the dismissal count (read by telemetry later; never reset by a tap).
    public static let dismissalCountKey = "shield.dismissals"

    /// Adds one dismissal to the count in `defaults` (the app group in the extension).
    public static func countDismissal(in defaults: UserDefaults?) {
        guard let defaults else { return }
        defaults.set(defaults.integer(forKey: dismissalCountKey) + 1, forKey: dismissalCountKey)
    }
}
