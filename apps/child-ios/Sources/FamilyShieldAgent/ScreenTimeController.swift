import Foundation
import os

#if canImport(ManagedSettings) && canImport(FamilyControls) && canImport(DeviceActivity)
import DeviceActivity
import FamilyControls
import ManagedSettings

/// FamilyShield's Screen Time controller for the child device (spec §6.2): requests
/// authorization, applies app and web shields, and schedules bedtime enforcement.
public final class ScreenTimeController {

    private static let logger = Logger(subsystem: "com.osratech.child", category: "ScreenTime")

    /// Dedicated store name for parent rule enforcement, separating rules from routine shields (IOS-05).
    public static let rulesStoreName = ManagedSettingsStore.Name("parentRules")

    /// ADR-0037: the app groups' shields, in a store of their own so a rule sync never overwrites them. Shields
    /// from several stores add up, so a blocked group and a synced rule both hold.
    public static let groupsStoreName = ManagedSettingsStore.Name("appGroups")

    /// Creates a controller backed by the rules `ManagedSettingsStore`.
    public init() {}

    /// Requests Screen Time authorization for a child account via the FamilyControls authorization center.
    ///
    /// NOTE: the host app target needs the Family Controls capability
    /// (com.apple.developer.family-controls); without it the request fails at runtime.
    public func requestAuthorization() async throws {
        try await AuthorizationCenter.shared.requestAuthorization(for: .child)
    }

    /// Shields the apps whose bundle identifiers appear in `packageIds`.
    /// Persists packageIds in shared app group (IOS-05) and applies tokens/blocked apps.
    public func applyBlockedApps(packageIds: [String]) {
        guard ensureAuthorized(#function) else { return }
        UserDefaults(suiteName: AgentIdentityStore.suiteName)?
            .set(packageIds, forKey: "apps.blockedBundleIdentifiers")

        let store = ManagedSettingsStore(named: Self.rulesStoreName)
        let tokens = TokenResolver.applicationTokens(forBundleIdentifiers: packageIds)
        store.shield.applications = tokens.isEmpty ? nil : tokens
        store.application.blockedApplications = Set(packageIds.map { Application(bundleIdentifier: $0) })
    }

    /// ADR-0037: shields exactly the apps, categories and websites of the blocked groups, nothing else. These are
    /// picker tokens, so iOS shows the OSRA shield (and Ask parent) instead of hiding the app, which is what
    /// `blockedApplications` does for the bundle-id rules above.
    public func applyGroups(_ groups: AppGroupList<FamilyActivitySelection>) {
        guard ensureAuthorized(#function) else { return }
        let store = ManagedSettingsStore(named: Self.groupsStoreName)
        let selections = groups.blockedSelections
        let apps = selections.reduce(into: Set<ApplicationToken>()) { $0.formUnion($1.applicationTokens) }
        let categories = selections.reduce(into: Set<ActivityCategoryToken>()) { $0.formUnion($1.categoryTokens) }
        let sites = selections.reduce(into: Set<WebDomainToken>()) { $0.formUnion($1.webDomainTokens) }
        store.shield.applications = apps.isEmpty ? nil : apps
        store.shield.applicationCategories = categories.isEmpty ? nil : .specific(categories, except: [])
        store.shield.webDomains = sites.isEmpty ? nil : sites
        store.shield.webDomainCategories = categories.isEmpty ? nil : .specific(categories, except: [])
    }

    /// Applies the web filter: `blockedDomains` feed the web-content filter policy while
    /// `blockedCategories` feed the web-domain and application category shields (IOS-03).
    public func applyWebFilter(blockedCategories: [String], blockedDomains: [String]) {
        guard ensureAuthorized(#function) else { return }
        let store = ManagedSettingsStore(named: Self.rulesStoreName)
        let domains = Set(blockedDomains.map { WebDomain(domain: $0) })
        store.webContent.blockedByFilter = domains.isEmpty
            ? WebContentSettings.FilterPolicy.none
            : WebContentSettings.FilterPolicy.specific(domains)
        let categories = TokenResolver.categoryTokens(forNames: blockedCategories)
        store.shield.webDomainCategories = categories.isEmpty
            ? nil
            : ShieldSettings.ActivityCategoryPolicy.specific(categories, except: [])
        store.shield.applicationCategories = categories.isEmpty
            ? nil
            : ShieldSettings.ActivityCategoryPolicy.specific(categories, except: [])
    }

    /// Registers a daily repeating bedtime schedule using RoutineWindow semantics (IOS-06).
    public func scheduleBedtime(window: RoutineWindow, routineID: String = "bedtime") throws {
        let (start, end) = window.toScheduleComponents()
        try scheduleBedtime(start: start, end: end, routineID: routineID)
    }

    /// Registers a daily repeating bedtime schedule under the activity name `bedtime.<routineID>`.
    public func scheduleBedtime(start: DateComponents, end: DateComponents, routineID: String = "bedtime") throws {
        guard ensureAuthorized(#function) else { return }
        guard let sHour = start.hour, let sMin = start.minute,
              let eHour = end.hour, let eMin = end.minute else {
            throw NSError(domain: "com.osratech.child", code: 400, userInfo: [
                NSLocalizedDescriptionKey: "Invalid start or end DateComponents: hour and minute required"
            ])
        }
        let sanitizedStart = DateComponents(hour: min(23, max(0, sHour)), minute: min(59, max(0, sMin)))
        let sanitizedEnd = DateComponents(hour: min(23, max(0, eHour)), minute: min(59, max(0, eMin)))

        let name = DeviceActivityName("bedtime.\(routineID)")
        // NOTE: DeviceActivitySchedule requires at least hour and minute in the
        // components, and a repeating interval must span at least 15 minutes.
        let schedule = DeviceActivitySchedule(
            intervalStart: sanitizedStart,
            intervalEnd: sanitizedEnd,
            repeats: true,
            warningTime: nil
        )
        try DeviceActivityCenter().startMonitoring(name, during: schedule, events: [:])
    }

    /// Enforces a synced rule set (5.5 PR C): blocked apps, the web filter, bedtime and the routines.
    /// Without Screen Time authorization each step logs and does nothing, as the methods above do. Any
    /// bedtime or routine activity the system refuses is recorded in `RuleStore.unscheduled()`.
    ///
    /// #475: throws when the rules were not put in force, so the caller does not report them as applied:
    /// `notAuthorized` without Screen Time authorization, `unscheduled` when the system refused a bedtime or
    /// routine activity.
    public func applyRules(_ rules: RuleSet) throws {
        applyBlockedApps(packageIds: rules.blockedBundleIdentifiers)
        applyGroups(AppGroupStore<FamilyActivitySelection>().load())
        applyWebFilter(blockedCategories: rules.webFilter.blockedCategories,
                       blockedDomains: rules.webFilter.blockedDomains)
        guard ensureAuthorized(#function) else { throw ApplyError.notAuthorized }
        var refused: [String] = []
        if let start = parseHHMM(rules.screenTime.bedtimeStart), let end = parseHHMM(rules.screenTime.bedtimeEnd) {
            do {
                try scheduleBedtime(start: DateComponents(hour: start.hour, minute: start.minute),
                                    end: DateComponents(hour: end.hour, minute: end.minute))
            } catch {
                // The old bedtime would keep running with the times the parent replaced (Claude on #380):
                // stop it, clearing its shield, so the phone never enforces a window nobody set.
                refused.append("bedtime: \(error.localizedDescription)")
                let center = DeviceActivityCenter()
                Self.stop(center.activities.filter { $0.rawValue.hasPrefix("bedtime.") }, center: center)
            }
        }
        refused += scheduleRoutines(RuleStore.routineSchedules())
        RuleStore.recordUnscheduled(refused)
        if !refused.isEmpty {
            Self.logger.error("\(refused.count) activities not monitored: \(refused.joined(separator: "; "), privacy: .public)")
            throw ApplyError.unscheduled(refused)
        }
    }

    /// Why `applyRules` did not put a rule set in force (#475).
    public enum ApplyError: Error, Equatable {
        case notAuthorized
        case unscheduled([String])
    }

    /// Registers one daily activity per routine (`RoutinePlan`); the monitor applies the shield only on the
    /// routine's weekdays (`ShieldPolicy`). Stale routine activities are stopped first, their shields cleared.
    /// Returns the routines the system refused.
    @discardableResult
    public func scheduleRoutines(_ routines: [RuleStore.RoutineSchedule]) -> [String] {
        guard ensureAuthorized(#function) else { return [] }
        let center = DeviceActivityCenter()
        Self.stop(center.activities.filter { $0.rawValue.hasPrefix("routine.") }, center: center)
        var refused: [String] = []
        for (routine, name) in zip(routines, RoutinePlan.activityNames(for: routines)) {
            guard let start = parseHHMM(routine.startTime), let end = parseHHMM(routine.endTime) else {
                refused.append("\(routine.name): bad time")
                continue
            }
            // Daily repeating; an end earlier than the start runs past midnight.
            let schedule = DeviceActivitySchedule(
                intervalStart: DateComponents(hour: start.hour, minute: start.minute),
                intervalEnd: DateComponents(hour: end.hour, minute: end.minute),
                repeats: true
            )
            do {
                try center.startMonitoring(DeviceActivityName(name), during: schedule)
            } catch {
                refused.append("\(routine.name): \(error.localizedDescription)")
            }
        }
        return refused
    }

    /// Removes every rule shield and schedule (consent withdrawn, or unpaired), including the shield of an
    /// interval that is running right now.
    public func clearRules() {
        let center = DeviceActivityCenter()
        Self.stop(center.activities, center: center)
        ManagedSettingsStore(named: Self.rulesStoreName).clearAllSettings()
        // Consent withdrawn stops every enforcement, the groups' shields included (the groups stay saved).
        ManagedSettingsStore(named: Self.groupsStoreName).clearAllSettings()
        RuleStore.recordUnscheduled([])
    }

    /// Clears each activity's named store, then stops monitoring it (`ActivityTeardown`).
    private static func stop(_ activities: [DeviceActivityName], center: DeviceActivityCenter) {
        guard !activities.isEmpty else { return }
        ActivityTeardown.stop(
            activities.map(\.rawValue),
            clearStore: { ManagedSettingsStore(named: ManagedSettingsStore.Name($0)).clearAllSettings() },
            stopMonitoring: { center.stopMonitoring($0.map { DeviceActivityName($0) }) }
        )
    }

    /// Logs a warning and returns false when Screen Time authorization is missing.
    private func ensureAuthorized(_ function: String) -> Bool {
        guard Self.isAuthorized else {
            Self.logger.warning("\(function): no Screen Time authorization; call requestAuthorization() first.")
            return false
        }
        return true
    }

    /// True when the app holds Screen Time authorization.
    private static var isAuthorized: Bool {
        AuthorizationCenter.shared.authorizationStatus == .approved
    }
}

/// The real [ScreenTimeAuthorizing]: FamilyControls' authorization center, for a child account (5.5, #372).
public final class FamilyControlsAuthorizer: ScreenTimeAuthorizing {
    public init() {}

    public var status: ScreenTimeStatus {
        switch AuthorizationCenter.shared.authorizationStatus {
        case .approved: return .approved
        case .denied: return .denied
        default: return .notDetermined
        }
    }

    public func request() async throws {
        try await ScreenTimeController().requestAuthorization()
    }
}

/// The picker's selection is what an app group holds; its counts are all the server may ever learn (ADR-0037).
extension FamilyActivitySelection: AppGroupSelection {
    public var counts: AppGroupCounts {
        AppGroupCounts(apps: applicationTokens.count, categories: categoryTokens.count, sites: webDomainTokens.count)
    }
}

/// Bridge from rule identifiers to Screen Time tokens. A bundle id yields a token only for an app the picker has
/// already returned, so for most rules it yields none and the app is hidden instead (`blockedApplications`).
///
/// ADR-0037: this no longer reads a saved picker selection. It used to return every picked token for any rule,
/// whatever bundle ids were asked for; picked apps now live in app groups and are shielded per group.
enum TokenResolver {
    static func applicationTokens(forBundleIdentifiers bundleIdentifiers: [String]) -> Set<ApplicationToken> {
        Set(bundleIdentifiers.compactMap { Application(bundleIdentifier: $0).token })
    }

    /// Category names in a rule cannot be turned into tokens without the picker, so they shield nothing here.
    static func categoryTokens(forNames names: [String]) -> Set<ActivityCategoryToken> {
        []
    }
}
#endif
