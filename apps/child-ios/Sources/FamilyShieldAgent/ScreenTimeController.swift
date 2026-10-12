import Foundation
import os

#if canImport(ManagedSettings) && canImport(FamilyControls) && canImport(DeviceActivity)
import DeviceActivity
import FamilyControls
import ManagedSettings

/// FamilyShield's Screen Time controller for the child device (spec §6.2): requests
/// authorization, applies app and web shields, and schedules bedtime enforcement.
public final class ScreenTimeController {

    private static let logger = Logger(subsystem: "dev.familyshield.agent", category: "ScreenTime")

    /// Dedicated store name for parent rule enforcement, separating rules from routine shields (IOS-05).
    public static let rulesStoreName = ManagedSettingsStore.Name("parentRules")

    /// Creates a controller backed by the rules `ManagedSettingsStore`.
    public init() {}

    /// Requests Screen Time authorization for a child account via the FamilyControls authorization center.
    ///
    /// NOTE: the host app target needs the Family Controls capability
    /// (com.apple.developer.family-controls); without it the request fails at runtime.
    public func requestAuthorization() async throws {
        try await AuthorizationCenter.shared.requestAuthorization(for: .child)
    }

    /// Applies shields using a parent-selected `FamilyActivitySelection` (IOS-02).
    public func applySelection(_ selection: FamilyActivitySelection) {
        guard ensureAuthorized(#function) else { return }
        SelectionStore.save(selection)
        let store = ManagedSettingsStore(named: Self.rulesStoreName)
        store.shield.applications = selection.applicationTokens.isEmpty ? nil : selection.applicationTokens
        store.shield.applicationCategories = selection.categoryTokens.isEmpty
            ? nil
            : ShieldSettings.ActivityCategoryPolicy.specific(selection.categoryTokens, except: [])
        store.shield.webDomains = selection.webDomainTokens.isEmpty ? nil : selection.webDomainTokens
    }

    /// Shields the apps whose bundle identifiers appear in `packageIds`.
    /// Persists packageIds in shared app group (IOS-05) and applies tokens/blocked apps.
    public func applyBlockedApps(packageIds: [String]) {
        guard ensureAuthorized(#function) else { return }
        UserDefaults(suiteName: SelectionStore.suiteName)?
            .set(packageIds, forKey: "apps.blockedBundleIdentifiers")

        let store = ManagedSettingsStore(named: Self.rulesStoreName)
        let tokens = TokenResolver.applicationTokens(forBundleIdentifiers: packageIds)
        store.shield.applications = tokens.isEmpty ? nil : tokens
        store.application.blockedApplications = Set(packageIds.map { Application(bundleIdentifier: $0) })
    }

    /// Persists the bedtime blocked bundle identifiers in the shared app group (IOS-05).
    public func setBedtimeBlockedApps(packageIds: [String]) {
        UserDefaults(suiteName: SelectionStore.suiteName)?
            .set(packageIds, forKey: "bedtime.blockedBundleIdentifiers")
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
            throw NSError(domain: "dev.familyshield.agent", code: 400, userInfo: [
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

/// Persistent store for FamilyActivitySelection picked by parent via FamilyActivityPicker (IOS-02).
public enum SelectionStore {
    public static let suiteName = "group.dev.familyshield.agent"
    public static let selectionKey = "agent.familyActivitySelection"

    public static func save(_ selection: FamilyActivitySelection) {
        guard let data = try? PropertyListEncoder().encode(selection) else { return }
        UserDefaults(suiteName: suiteName)?.set(data, forKey: selectionKey)
    }

    public static func load() -> FamilyActivitySelection {
        guard let data = UserDefaults(suiteName: suiteName)?.data(forKey: selectionKey),
              let selection = try? PropertyListDecoder().decode(FamilyActivitySelection.self, from: data) else {
            return FamilyActivitySelection()
        }
        return selection
    }
}

/// Best-effort bridge from rule identifiers (bundle identifiers, category names) to
/// the opaque tokens the Screen Time API requires (IOS-02).
enum TokenResolver {

    /// Returns application tokens from the persisted FamilyActivitySelection or synthesizes from bundle IDs.
    static func applicationTokens(forBundleIdentifiers bundleIdentifiers: [String]) -> Set<ApplicationToken> {
        let selection = SelectionStore.load()
        if !selection.applicationTokens.isEmpty {
            return selection.applicationTokens
        }
        return Set(bundleIdentifiers.compactMap { Application(bundleIdentifier: $0).token })
    }

    /// Returns category tokens from persisted FamilyActivitySelection.
    static func categoryTokens(forNames names: [String]) -> Set<ActivityCategoryToken> {
        let selection = SelectionStore.load()
        return selection.categoryTokens
    }

    /// Returns web domain tokens from persisted FamilyActivitySelection.
    static func webDomainTokens() -> Set<WebDomainToken> {
        let selection = SelectionStore.load()
        return selection.webDomainTokens
    }
}
#endif
