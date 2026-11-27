import Foundation

/// An authenticated bonus command belongs to the local day on which it was issued.
struct DailyScreenTimeGrant: Codable, Equatable {
    let id: String
    let minutes: Int
    let issuedAt: Date
}

enum DailyScreenTimeGrantOutcome: Equatable {
    case applied
    case refused(String)
    case retry
}

struct DailyScreenTimeBonuses: Codable, Equatable {
    private(set) var grants: [DailyScreenTimeGrant] = []

    mutating func record(_ grant: DailyScreenTimeGrant, at now: Date, calendar: Calendar) -> Bool {
        guard !grant.id.isEmpty, grant.minutes > 0,
              calendar.isDate(grant.issuedAt, inSameDayAs: now) else { return false }
        grants.removeAll { !calendar.isDate($0.issuedAt, inSameDayAs: now) }
        if let existing = grants.first(where: { $0.id == grant.id }) {
            return existing == grant
        }
        grants.append(grant)
        return true
    }

    func minutes(at date: Date, calendar: Calendar) -> Int {
        grants.reduce(into: 0) { total, grant in
            guard calendar.isDate(grant.issuedAt, inSameDayAs: date) else { return }
            total += min(grant.minutes, DailyScreenTimeLimits.maximumMinutes - total)
        }
    }
}

struct DailyScreenTimeLimits: Codable, Equatable {
    struct Threshold: Equatable {
        let name: String
        let minutes: Int
    }

    static let maximumMinutes = 24 * 60

    let weekdayMinutes: Int
    let weekendMinutes: Int

    init(weekdayMinutes: Int, weekendMinutes: Int) {
        self.weekdayMinutes = weekdayMinutes
        self.weekendMinutes = weekendMinutes
    }

    init(_ screenTime: RuleSet.ScreenTime) {
        self.init(weekdayMinutes: screenTime.dailyLimitMinutes, weekendMinutes: screenTime.weekendLimitMinutes)
    }

    private var weekdayThreshold: Threshold? { baseline("weekday", minutes: weekdayMinutes) }
    private var weekendThreshold: Threshold? {
        guard weekdayMinutes > 0 else { return nil }
        return baseline("weekend", minutes: weekendMinutes > 0 ? weekendMinutes : weekdayMinutes)
    }

    private func baseline(_ name: String, minutes: Int) -> Threshold? {
        guard minutes > 0 else { return nil }
        let limit = min(minutes, Self.maximumMinutes)
        return Threshold(name: "\(name).\(limit)", minutes: limit)
    }

    func threshold(at date: Date, calendar: Calendar, bonuses: DailyScreenTimeBonuses) -> Threshold? {
        let day = calendar.component(.weekday, from: date)
        let base = day == 1 || day == 7 ? weekendThreshold : weekdayThreshold
        guard let base else { return nil }
        let bonus = bonuses.minutes(at: date, calendar: calendar)
        guard bonus > 0 else { return base }
        let minutes = min(base.minutes + bonus, Self.maximumMinutes)
        guard minutes > base.minutes else { return base }
        let dayStart = Int(calendar.startOfDay(for: date).timeIntervalSince1970)
        return Threshold(name: "bonus.\(dayStart).\(minutes)", minutes: minutes)
    }

    /// Both base thresholds repeat. The monitor applies only the active day's event.
    func events(at date: Date, calendar: Calendar, bonuses: DailyScreenTimeBonuses) -> [Threshold] {
        var events = [weekdayThreshold, weekendThreshold].compactMap { $0 }
        if let effective = threshold(at: date, calendar: calendar, bonuses: bonuses),
           !events.contains(effective) {
            events.append(effective)
        }
        return events
    }
}

struct DailyScreenTimeState: Codable, Equatable {
    let deviceID: String
    var limits: DailyScreenTimeLimits
    var bonuses = DailyScreenTimeBonuses()
    private var reachedDay: Date?
    private var reachedMinutes: Int?

    init(deviceID: String, limits: DailyScreenTimeLimits) {
        self.deviceID = deviceID
        self.limits = limits
    }

    func isExhausted(at date: Date, calendar: Calendar) -> Bool {
        guard let threshold = limits.threshold(at: date, calendar: calendar, bonuses: bonuses),
              let reachedDay, calendar.isDate(reachedDay, inSameDayAs: date),
              let reachedMinutes else { return false }
        return reachedMinutes >= threshold.minutes
    }

    /// A queued callback for the previous allowance must never undo a grant.
    mutating func reach(_ event: String, at date: Date, calendar: Calendar) -> Bool {
        guard let threshold = limits.threshold(at: date, calendar: calendar, bonuses: bonuses),
              threshold.name == event, !isExhausted(at: date, calendar: calendar) else { return false }
        reachedDay = calendar.startOfDay(for: date)
        reachedMinutes = threshold.minutes
        return true
    }
}

#if os(iOS)
import Darwin
import DeviceActivity
import FamilyControls
import ManagedSettings

@available(iOS 17.4, *)
enum DailyScreenTimeMonitor {
    static let activity = DeviceActivityName("dailyScreenTime")
    private static let store = ManagedSettingsStore(named: ManagedSettingsStore.Name(activity.rawValue))

    private enum StateError: Error {
        case unavailable, pairingChanged
    }

    static func configure(_ rules: RuleSet, deviceID: String) throws {
        let limits = DailyScreenTimeLimits(rules.screenTime)
        try withState { url, current in
            guard !deviceID.isEmpty, AlertReporter.pairedDeviceId() == deviceID else { throw StateError.pairingChanged }
            var state = current.flatMap { $0.deviceID == deviceID ? $0 : nil }
                ?? DailyScreenTimeState(deviceID: deviceID, limits: limits)
            state.limits = limits
            let now = Date()
            let calendar = Calendar.current
            try saveAndRegister(state, previous: current, at: url, now: now, calendar: calendar)
            updateShield(for: state, at: now, calendar: calendar)
        }
    }

    static func grant(_ grant: DailyScreenTimeGrant, for identity: AgentIdentity,
                      rules: RuleSet) -> DailyScreenTimeGrantOutcome {
        guard AuthorizationCenter.shared.authorizationStatus == .approved else {
            return .refused("screen_time_not_authorized")
        }
        let limits = DailyScreenTimeLimits(rules.screenTime)
        guard limits.weekdayMinutes > 0 else { return .refused("daily_limit_unavailable") }
        do {
            return try withState { url, current in
                guard AlertReporter.pairedDeviceId() == identity.deviceId else { return .refused("pairing_changed") }
                guard var state = current, state.deviceID == identity.deviceId, state.limits == limits else { return .retry }
                let now = Date()
                let calendar = Calendar.current
                guard state.bonuses.record(grant, at: now, calendar: calendar) else { return .refused("invalid_bonus_grant") }
                try saveAndRegister(state, previous: current, at: url, now: now, calendar: calendar)
                updateShield(for: state, at: now, calendar: calendar)
                return .applied
            }
        } catch {
            return .retry
        }
    }

    static func intervalChanged() {
        try? withState { _, state in
            let current = state.flatMap { $0.deviceID == AlertReporter.pairedDeviceId() ? $0 : nil }
            updateShield(for: current, at: Date(), calendar: .current)
        }
    }

    static func reached(_ event: DeviceActivityEvent.Name) -> Bool {
        (try? withState { url, current in
            guard var state = current, state.deviceID == AlertReporter.pairedDeviceId() else { return false }
            let now = Date()
            let calendar = Calendar.current
            guard state.reach(event.rawValue, at: now, calendar: calendar) else { return false }
            try save(state, at: url)
            updateShield(for: state, at: now, calendar: calendar)
            return true
        }) ?? false
    }

    /// U105: whether the child's own daily limit is what holds the shield, and when the day turns over.
    ///
    /// Read from the same app-group state the shield is drawn from, so the block screen and the enforcement
    /// cannot disagree about whether the limit is spent.
    static func dailyLimitStatus(now: Date = Date(),
                                 calendar: Calendar = .current) -> (exhausted: Bool, resetsAt: Date) {
        let resetsAt = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
        let exhausted = (try? withState { _, current in
            guard let state = current, state.deviceID == AlertReporter.pairedDeviceId() else { return false }
            return state.isExhausted(at: now, calendar: calendar)
        }) ?? false
        return (exhausted, resetsAt)
    }

    static func clear() {
        do {
            try withState { url, _ in
                try? FileManager.default.removeItem(at: url)
                DeviceActivityCenter().stopMonitoring([activity])
                store.clearAllSettings()
            }
        } catch {
            DeviceActivityCenter().stopMonitoring([activity])
            store.clearAllSettings()
        }
    }

    private static func saveAndRegister(_ state: DailyScreenTimeState, previous: DailyScreenTimeState?, at url: URL,
                                        now: Date, calendar: Calendar) throws {
        if state != previous { try save(state, at: url) }
        let center = DeviceActivityCenter()
        let thresholds = state.limits.events(at: now, calendar: calendar, bonuses: state.bonuses)
        let events = Dictionary(uniqueKeysWithValues: thresholds.map {
            (DeviceActivityEvent.Name($0.name),
             DeviceActivityEvent(threshold: DateComponents(minute: $0.minutes), includesPastActivity: true))
        })
        guard !events.isEmpty else {
            if center.activities.contains(activity) { center.stopMonitoring([activity]) }
            return
        }
        // Read back the registered events even if the grant is already persisted. The app can
        // be terminated between writing the state and replacing the system's schedule.
        guard center.events(for: activity) != events else { return }
        let schedule = DeviceActivitySchedule(intervalStart: DateComponents(hour: 0, minute: 0),
                                              intervalEnd: DateComponents(hour: 23, minute: 59, second: 59),
                                              repeats: true)
        do {
            try center.startMonitoring(activity, during: schedule, events: events)
        } catch {
            if let previous {
                try save(previous, at: url)
            } else {
                try FileManager.default.removeItem(at: url)
            }
            throw error
        }
    }

    private static func updateShield(for state: DailyScreenTimeState?, at date: Date, calendar: Calendar) {
        guard let state, state.isExhausted(at: date, calendar: calendar) else {
            store.clearAllSettings()
            return
        }
        let exceptions = RuleStore.alwaysAllowedApps() + RuleStore.allowedApps() + ShieldPolicy.essentialApps
            + ["com.osratech.child"]
        store.shield.applicationCategories = .all(except: TokenResolver.applicationTokens(forBundleIdentifiers: exceptions))
        store.shield.webDomainCategories = .all()
    }

    /// Both the app and the activity extension update this state. Use a separate lock file so atomic
    /// replacement of the state file never replaces a lock another process is waiting on.
    private static func withState<T>(_ action: (URL, DailyScreenTimeState?) throws -> T) throws -> T {
        guard let directory = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AgentIdentityStore.suiteName)
        else { throw StateError.unavailable }
        let lock = directory.appendingPathComponent("daily-screen-time.lock")
        let descriptor = open(lock.path, O_CREAT | O_RDWR, mode_t(S_IRUSR | S_IWUSR))
        guard descriptor >= 0 else { throw StateError.unavailable }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw StateError.unavailable }
        defer { flock(descriptor, LOCK_UN) }
        let url = directory.appendingPathComponent("daily-screen-time.json")
        let state = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(DailyScreenTimeState.self, from: $0) }
        return try action(url, state)
    }

    private static func save(_ state: DailyScreenTimeState, at url: URL) throws {
        try JSONEncoder().encode(state).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
#endif
