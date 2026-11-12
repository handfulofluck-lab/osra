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

    /// The app-group key of the dismissal count (read by telemetry later; never reset by a tap).
    public static let dismissalCountKey = "shield.dismissals"

    /// Adds one dismissal to the count in `defaults` (the app group in the extension).
    public static func countDismissal(in defaults: UserDefaults?) {
        guard let defaults else { return }
        defaults.set(defaults.integer(forKey: dismissalCountKey) + 1, forKey: dismissalCountKey)
    }
}
