import Foundation

/// iOS usage collection, #1046: what the phone is allowed to tell the parent about app use.
///
/// Screen Time never exposes an installed-app inventory — only opaque tokens for apps a parent picked in the
/// `FamilyActivityPicker` — so the collector can report durations for **those apps alone**. This type is the
/// contract between the report extension (which can see token → name and token → minutes) and everything after it:
/// a small, bounded, platform-tagged snapshot. It is plain `Codable` and platform-neutral on purpose, so the policy
/// below is tested on macOS without FamilyControls, the way `BlockedAppHiding` is.
public struct UsageSnapshot: Codable, Equatable {
    /// One app's use for one day. [bundleId] is the identifier the extension resolved; [label] is the name it showed,
    /// so the parent never has to guess what a bundle id means.
    public struct Entry: Codable, Equatable {
        public var bundleId: String
        public var label: String
        public var minutes: Int

        public init(bundleId: String, label: String, minutes: Int) {
            self.bundleId = bundleId
            self.label = label
            self.minutes = minutes
        }
    }

    /// `yyyy-MM-dd` in the phone's calendar: a day is the child's day, not UTC's.
    public var day: String
    /// Newest-first by minutes, at most [UsagePolicy.maxEntries].
    public var entries: [Entry]
    /// Always `ios`: the parent shows this under its own heading rather than in one column with Android.
    public var source: String

    public init(day: String, entries: [Entry], source: String = UsageSnapshot.iosSource) {
        self.day = day
        self.entries = entries
        self.source = source
    }

    public static let iosSource = "ios"
    public static let appGroupKey = "usage.daily.v1"
}

/// The rules that keep a reported day small, ordered and honest. Pure, so each one has a row that fails without it.
public enum UsagePolicy {
    /// The most apps one day reports. A parent with 60 apps open does not need a 60-row list, and the App Group
    /// snapshot is written by an extension with little memory to spare.
    public static let maxEntries = 20
    /// Below this, a row is noise: Apple's own numbers are minute-grained and rounded.
    public static let minimumMinutes = 1

    /// Build one day from what the extension collected: drop sub-minute rows and anything unnamed, merge duplicates
    /// that resolved to the same bundle id, sort by minutes and keep the head of the list.
    public static func snapshot(day: String, collected: [UsageSnapshot.Entry]) -> UsageSnapshot {
        var merged: [String: UsageSnapshot.Entry] = [:]
        for entry in collected {
            let bundleId = entry.bundleId.trimmingCharacters(in: .whitespacesAndNewlines)
            let label = entry.label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !bundleId.isEmpty, !label.isEmpty, entry.minutes >= minimumMinutes else { continue }
            if var existing = merged[bundleId] {
                existing.minutes += entry.minutes
                if existing.label.isEmpty { existing.label = label }
                merged[bundleId] = existing
            } else {
                merged[bundleId] = UsageSnapshot.Entry(bundleId: bundleId, label: label, minutes: entry.minutes)
            }
        }
        let sorted = merged.values.sorted {
            $0.minutes == $1.minutes ? $0.bundleId < $1.bundleId : $0.minutes > $1.minutes
        }
        return UsageSnapshot(day: day, entries: Array(sorted.prefix(maxEntries)))
    }

    /// The day key the snapshot uses, from a date and a calendar. Injectable so a test does not depend on today.
    public static func dayKey(for date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = parts.year, let month = parts.month, let day = parts.day else { return "" }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    /// Whether a snapshot is worth sending at all. An empty day is not "no use" — it is "nothing selected or the
    /// phone was off" — and the parent app must say that rather than show a zero.
    public static func isReportable(_ snapshot: UsageSnapshot) -> Bool {
        !snapshot.day.isEmpty && !snapshot.entries.isEmpty
    }
}
