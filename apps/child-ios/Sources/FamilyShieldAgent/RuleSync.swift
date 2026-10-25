import Foundation

/// The child's rules as `GET /v1/rules/:childId` returns them (`services/api/src/lib/ruleSync.ts`
/// `toApiRuleSet`), reduced to what the iOS agent enforces (5.5 PR C, #372). Unknown fields are ignored,
/// so a server that adds one does not break the phone.
public struct RuleSet: Decodable, Equatable {
    public struct ScreenTime: Decodable, Equatable {
        public var dailyLimitMinutes: Int
        public var weekendLimitMinutes: Int
        public var bedtimeStart: String
        public var bedtimeEnd: String
        public var schoolHours: SchoolHours
    }

    public struct SchoolHours: Decodable, Equatable {
        public var start: String
        public var end: String
        /// 1=Mon..7=Sun, the contract across the API, the parent app and every agent.
        public var days: [Int]
    }

    public struct WebFilter: Decodable, Equatable {
        public var blockedCategories: [String]
        public var allowedDomains: [String]
        public var blockedDomains: [String]
        public var safeSearchEnforced: Bool
    }

    public struct AppRule: Decodable, Equatable {
        public var packageId: String
        public var appName: String
        /// "allow", "block" or "time_limit".
        public var action: String
        public var dailyLimitMinutes: Int?
    }

    public struct Routine: Decodable, Equatable {
        public var id: String?
        public var name: String
        public var startTime: String
        public var endTime: String
        /// 1=Mon..7=Sun.
        public var days: [Int]
        public var blockedApps: [String]
        public var allowedApps: [String]
    }

    public var screenTime: ScreenTime
    public var webFilter: WebFilter
    public var appRules: [AppRule]
    public var routines: [Routine]
    public var alwaysAllowedApps: [String]

    /// Bundle identifiers the parent blocked outright (`action == "block"`).
    public var blockedBundleIdentifiers: [String] {
        appRules.filter { $0.action == "block" }.map(\.packageId)
    }

    /// Bundle identifiers the parent explicitly allowed (`action == "allow"`).
    public var allowedBundleIdentifiers: [String] {
        appRules.filter { $0.action == "allow" }.map(\.packageId)
    }
}

/// Day-of-week conversion between the rules contract and Foundation.
public enum Weekday {
    /// Rules use 1=Mon..7=Sun; `DateComponents.weekday` uses 1=Sun..7=Sat. Returns nil outside 1...7, so a
    /// bad value is dropped rather than scheduled on the wrong day.
    public static func swiftWeekday(ruleDay: Int) -> Int? {
        guard (1...7).contains(ruleDay) else { return nil }
        return ruleDay % 7 + 1
    }
}

/// Parses "HH:MM" into hour and minute; nil when malformed.
public func parseHHMM(_ value: String) -> (hour: Int, minute: Int)? {
    let parts = value.split(separator: ":")
    guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]),
          (0...23).contains(h), (0...59).contains(m) else { return nil }
    return (h, m)
}

/// Fetches the paired child's rules with the device token.
public struct RuleSyncClient {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// Errors a sync can end in; the caller keeps the last rules it stored.
    public enum SyncError: Error, Equatable {
        case httpError(status: Int)
        case unusableResponse
    }

    public func fetch(for identity: AgentIdentity) async throws -> RuleSet {
        var request = URLRequest(url: identity.apiBaseURL
            .appendingPathComponent("v1/rules")
            .appendingPathComponent(identity.childId))
        request.setValue("Bearer \(identity.deviceToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        // 428 means consent was withdrawn: the device must stop enforcing, which the caller does by clearing.
        guard status == 200 else { throw SyncError.httpError(status: status) }
        guard let rules = try? JSONDecoder().decode(RuleSet.self, from: data) else { throw SyncError.unusableResponse }
        return rules
    }
}

/// Writes the synced rules into the app group, where the monitor and shield extensions read them.
public enum RuleStore {
    enum Keys {
        static let blockedApps = "apps.blockedBundleIdentifiers"
        static let allowedApps = "rules.allowedApps"
        static let alwaysAllowedApps = "rules.alwaysAllowedApps"
        static let bedtimeStart = "rules.bedtimeStart"
        static let bedtimeEnd = "rules.bedtimeEnd"
        static let blockedDomains = "rules.blockedDomains"
        static let blockedCategories = "rules.blockedCategories"
        static let routineSchedules = "rules.routineSchedules"
        static let unscheduled = "rules.unscheduledActivities"
        static let syncedAt = "rules.syncedAt"
    }

    /// One routine, with its days already in Foundation's weekday numbering.
    public struct RoutineSchedule: Codable, Equatable {
        public var name: String
        public var startTime: String
        public var endTime: String
        public var swiftWeekdays: [Int]
        public var blockedApps: [String]
        public var allowedApps: [String]
    }

    @discardableResult
    public static func save(_ rules: RuleSet, now: Date = Date()) -> Bool {
        guard let defaults = UserDefaults(suiteName: AgentIdentityStore.suiteName) else { return false }
        defaults.set(rules.blockedBundleIdentifiers, forKey: Keys.blockedApps)
        defaults.set(rules.allowedBundleIdentifiers, forKey: Keys.allowedApps)
        defaults.set(rules.alwaysAllowedApps, forKey: Keys.alwaysAllowedApps)
        defaults.set(rules.screenTime.bedtimeStart, forKey: Keys.bedtimeStart)
        defaults.set(rules.screenTime.bedtimeEnd, forKey: Keys.bedtimeEnd)
        defaults.set(rules.webFilter.blockedDomains, forKey: Keys.blockedDomains)
        defaults.set(rules.webFilter.blockedCategories, forKey: Keys.blockedCategories)
        let schedules = rules.routines.map {
            RoutineSchedule(name: $0.name, startTime: $0.startTime, endTime: $0.endTime,
                            swiftWeekdays: $0.days.compactMap(Weekday.swiftWeekday(ruleDay:)),
                            blockedApps: $0.blockedApps, allowedApps: $0.allowedApps)
        }
        defaults.set(try? JSONEncoder().encode(schedules), forKey: Keys.routineSchedules)
        defaults.set(now.timeIntervalSince1970, forKey: Keys.syncedAt)
        return true
    }

    public static func routineSchedules() -> [RoutineSchedule] {
        guard let data = defaults?.data(forKey: Keys.routineSchedules) else { return [] }
        return (try? JSONDecoder().decode([RoutineSchedule].self, from: data)) ?? []
    }

    public static func allowedApps() -> [String] { defaults?.stringArray(forKey: Keys.allowedApps) ?? [] }
    public static func alwaysAllowedApps() -> [String] { defaults?.stringArray(forKey: Keys.alwaysAllowedApps) ?? [] }

    /// Records the bedtime or routine activities the system refused to monitor, in one place: the parent
    /// would otherwise believe they apply. Empty when everything was registered.
    public static func recordUnscheduled(_ names: [String]) {
        defaults?.set(names, forKey: Keys.unscheduled)
    }

    public static func unscheduled() -> [String] { defaults?.stringArray(forKey: Keys.unscheduled) ?? [] }

    /// Removes every synced rule: on unpairing, and when the server answers 428 (consent withdrawn).
    public static func clear() {
        guard let defaults else { return }
        for key in [Keys.blockedApps, Keys.allowedApps, Keys.alwaysAllowedApps, Keys.bedtimeStart, Keys.bedtimeEnd,
                    Keys.blockedDomains, Keys.blockedCategories, Keys.routineSchedules, Keys.unscheduled, Keys.syncedAt] {
            defaults.removeObject(forKey: key)
        }
    }

    private static var defaults: UserDefaults? { UserDefaults(suiteName: AgentIdentityStore.suiteName) }
}

/// What a running bedtime or routine interval shields. A pure decision, so the SwiftPM tests can reach it;
/// the monitor extension applies it (`FamilyShieldDeviceActivityMonitor.intervalDidStart`).
///
/// Android's rule (`RuleEngine.kt`): during bedtime, and during a routine that lists `allowedApps`,
/// everything is blocked except what is allowed. A routine that only lists `blockedApps` blocks those.
public enum ShieldPolicy: Equatable {
    /// Shield every app except these bundle identifiers (`.all(except:)`).
    case allExcept([String])
    /// Shield exactly these bundle identifiers.
    case only([String])
    /// Shield nothing for this activity (not today, or nothing to block).
    case none

    /// Always reachable, as Android's essential-apps rule keeps the dialer (#165). Whether Phone stays
    /// reachable under `.all(except:)` can only be confirmed on a signed device (5.1).
    public static let essentialApps = ["com.apple.mobilephone"]

    /// The decision for `activity` (`bedtime.<id>` or `routine.<index>`) starting on `weekday`
    /// (Foundation numbering, 1=Sun..7=Sat). An overnight routine is judged by the day it started on,
    /// which is the day `intervalDidStart` runs.
    public static func decide(activity: String, weekday: Int, alwaysAllowed: [String], allowed: [String],
                              routines: [RuleStore.RoutineSchedule]) -> ShieldPolicy {
        let everywhere = alwaysAllowed + allowed + essentialApps
        if activity.hasPrefix("bedtime.") { return .allExcept(unique(everywhere)) }
        let parts = activity.split(separator: ".")
        guard parts.count == 2, parts[0] == "routine", let index = Int(parts[1]), routines.indices.contains(index)
        else { return .none }
        let routine = routines[index]
        guard routine.swiftWeekdays.contains(weekday) else { return .none }
        if !routine.allowedApps.isEmpty { return .allExcept(unique(everywhere + routine.allowedApps)) }
        return routine.blockedApps.isEmpty ? .none : .only(routine.blockedApps)
    }

    /// `decide` with the rules stored by the last sync.
    public static func current(activity: String, weekday: Int) -> ShieldPolicy {
        decide(activity: activity, weekday: weekday, alwaysAllowed: RuleStore.alwaysAllowedApps(),
               allowed: RuleStore.allowedApps(), routines: RuleStore.routineSchedules())
    }

    private static func unique(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }
}

/// The activities to monitor for the synced routines: one daily activity per routine, whatever its days.
/// The weekday check happens when an interval starts (`ShieldPolicy.decide`), so a seven-day routine costs
/// one activity, not seven, against `DeviceActivityCenter`'s per-app cap (`excessiveActivities`).
public enum RoutinePlan {
    public static func activityNames(for routines: [RuleStore.RoutineSchedule]) -> [String] {
        routines.indices.map { "routine.\($0)" }
    }
}

/// Stopping activities without leaving a shield behind: a running interval keeps its shield in its own
/// named store, which only `intervalDidEnd` would clear. So each store is cleared before monitoring stops.
public enum ActivityTeardown {
    public static func stop(_ names: [String], clearStore: (String) -> Void, stopMonitoring: ([String]) -> Void) {
        names.forEach(clearStore)
        stopMonitoring(names)
    }
}

/// One sync: fetch the rules with the device token, store them for the extensions, and enforce them.
public enum RuleSyncer {
    public enum Outcome: Equatable {
        case notPaired
        case synced(RuleSet)
        /// 428: consent was withdrawn, so every stored rule and shield was removed (ADR-0008 §2b).
        case consentWithdrawn
        /// Any other failure; the last stored rules stay in force.
        case failed(String)
    }

    @discardableResult
    public static func syncNow(client: RuleSyncClient = RuleSyncClient(), enforce: Bool = true) async -> Outcome {
        guard let identity = AgentIdentityStore.load() else { return .notPaired }
        do {
            let rules = try await client.fetch(for: identity)
            RuleStore.save(rules)
            #if canImport(ManagedSettings) && canImport(FamilyControls) && canImport(DeviceActivity)
            if enforce { ScreenTimeController().applyRules(rules) }
            #endif
            return .synced(rules)
        } catch RuleSyncClient.SyncError.httpError(status: 428) {
            RuleStore.clear()
            #if canImport(ManagedSettings) && canImport(FamilyControls) && canImport(DeviceActivity)
            if enforce { ScreenTimeController().clearRules() }
            #endif
            return .consentWithdrawn
        } catch {
            return .failed(String(describing: error))
        }
    }
}
