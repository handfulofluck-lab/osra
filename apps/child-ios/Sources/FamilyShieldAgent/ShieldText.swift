import Foundation

/// What the iPhone block screen says (#511): the title, the window line and the button labels, in English or
/// Arabic. Pure, so the SwiftPM tests reach it; the Shield Configuration extension only calls `current`.
///
/// Android parity (#496, #502): the line names the window holding the app and when it ends ("Blocked by
/// Bedtime until 07:00"), and nothing at all when no window holds it. An app the parent blocked outright is the
/// rule itself, not a window, so it gets no line, as `RuleEngine.evaluateWithReason` answers on Android.
public struct ShieldText: Equatable {
    public var title: String
    /// The window line, or nil when no window holds the app.
    public var subtitle: String?
    /// "Request access": keeps the shield up and tells the parent.
    public var primaryButton: String
    /// "Exit to Home screen": closes the blocked app.
    public var secondaryButton: String

    /// The windows the iPhone enforces: bedtime and the routines (`ScreenTimeController.applyRules`). School
    /// hours are not scheduled on iOS, so the screen never names them.
    public enum Window: Equatable {
        case bedtime(endsAt: String)
        case routine(name: String, endsAt: String)
    }

    /// First Strong Isolate and Pop Directional Isolate (the #506 ruling): an English routine name or the time
    /// inside the Arabic line keeps its own direction and does not reorder the sentence around it.
    static let fsi = "\u{2068}"
    static let pdi = "\u{2069}"

    /// The window that holds `bundleIdentifier` at `now`, read on the clock of `timeZone`. Mirrors
    /// `ShieldPolicy.decide` and Android's order: an explicit block is no window; routines are read before
    /// bedtime; an always-allowed or essential app is held by nothing.
    ///
    /// A routine's weekday is the day it started on, so 01:00 inside a 22:00–02:00 routine counts the day before.
    public static func activeWindow(bundleIdentifier: String?, now: Date, timeZone: TimeZone,
                                    bedtimeStart: String?, bedtimeEnd: String?,
                                    routines: [RuleStore.RoutineSchedule], blocked: [String],
                                    alwaysAllowed: [String], allowed: [String]) -> Window? {
        // A website shield comes from the web filter, which is not a window.
        guard let app = bundleIdentifier else { return nil }
        if blocked.contains(app) { return nil }
        let everywhere = Set(alwaysAllowed + allowed + ShieldPolicy.essentialApps)
        if everywhere.contains(app) { return nil }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.hour, .minute, .weekday], from: now)
        guard let hour = parts.hour, let minute = parts.minute, let weekday = parts.weekday else { return nil }
        let nowMinutes = hour * 60 + minute
        let yesterday = weekday == 1 ? 7 : weekday - 1

        for routine in routines {
            guard let start = minutes(routine.startTime), let end = minutes(routine.endTime),
                  let startedOn = startDay(now: nowMinutes, start: start, end: end, today: weekday, yesterday: yesterday),
                  routine.swiftWeekdays.contains(startedOn) else { continue }
            let holds = routine.allowedApps.isEmpty
                ? routine.blockedApps.contains(app)
                : !routine.allowedApps.contains(app)
            if holds { return .routine(name: routine.name, endsAt: routine.endTime) }
        }

        if let startText = bedtimeStart, let endText = bedtimeEnd,
           let start = minutes(startText), let end = minutes(endText),
           startDay(now: nowMinutes, start: start, end: end, today: weekday, yesterday: yesterday) != nil {
            return .bedtime(endsAt: endText)
        }
        return nil
    }

    /// The screen's text for `window` in `language` ("en" or "ar"; anything else falls back to English).
    public static func make(window: Window?, language: String) -> ShieldText {
        let table = strings(for: language)
        var subtitle: String?
        if let window {
            let label: String
            let endsAt: String
            switch window {
            case .bedtime(let end):
                label = table("block_window_bedtime")
                endsAt = end
            case .routine(let name, let end):
                // The routine's name exactly as the parent typed it; a blank one has nothing to show, as on Android.
                label = name.trimmingCharacters(in: .whitespaces).isEmpty ? "" : name
                endsAt = end
            }
            if !label.isEmpty {
                subtitle = String(format: table("block_window_line"), fsi + label + pdi, fsi + endsAt + pdi)
            }
        }
        return ShieldText(title: table("block_title_blocked"), subtitle: subtitle,
                          primaryButton: table("block_request_access"), secondaryButton: table("block_exit_home"))
    }

    /// The text for an app shielded right now, from the rules the last sync stored in the app group. The clock is
    /// the phone's own: DeviceActivity starts and ends each interval on the device's local time, so that is the
    /// clock the shield is actually held by.
    public static func current(bundleIdentifier: String?, now: Date = Date(), timeZone: TimeZone = .current,
                               language: String = preferredLanguage()) -> ShieldText {
        let window = activeWindow(bundleIdentifier: bundleIdentifier, now: now, timeZone: timeZone,
                                  bedtimeStart: RuleStore.bedtimeStart(), bedtimeEnd: RuleStore.bedtimeEnd(),
                                  routines: RuleStore.routineSchedules(), blocked: RuleStore.blockedApps(),
                                  alwaysAllowed: RuleStore.alwaysAllowedApps(), allowed: RuleStore.allowedApps())
        return make(window: window, language: language)
    }

    /// The phone's language among the ones the block screen ships.
    public static func preferredLanguage() -> String {
        Bundle.preferredLocalizations(from: ["en", "ar"], forPreferences: Locale.preferredLanguages).first ?? "en"
    }

    // MARK: - Helpers

    private static func minutes(_ hhmm: String) -> Int? {
        parseHHMM(hhmm).map { $0.hour * 60 + $0.minute }
    }

    /// The weekday the window running at `now` started on, or nil when no window is running. Equal start and end
    /// is an empty window, as in the agent.
    private static func startDay(now: Int, start: Int, end: Int, today: Int, yesterday: Int) -> Int? {
        if start == end { return nil }
        if start < end { return (start..<end).contains(now) ? today : nil }
        if now >= start { return today }
        if now < end { return yesterday }
        return nil
    }

    /// A lookup into the package's `Localizable.strings` for `language`, English when that table is missing.
    private static func strings(for language: String) -> (String) -> String {
        let bundle = Bundle.module.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:))
            ?? Bundle.module.path(forResource: "en", ofType: "lproj").flatMap(Bundle.init(path:))
            ?? Bundle.module
        return { key in bundle.localizedString(forKey: key, value: nil, table: nil) }
    }
}
