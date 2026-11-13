import Foundation

/// #690: when a resume runs the app-open drain and sync. Not within `minInterval` of the last one, so the
/// resume that follows every cold launch does not fetch the rules twice.
public enum ResumeRefresh {
    public static let minInterval: TimeInterval = 30

    public static func isDue(last: Date, now: Date) -> Bool {
        now.timeIntervalSince(last) >= minInterval
    }
}
