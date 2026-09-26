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

    /// Creates a controller backed by the default `ManagedSettingsStore`.
    public init() {}

    /// Requests Screen Time authorization for a child account via the FamilyControls authorization center.
    ///
    /// NOTE: the host app target needs the Family Controls capability
    /// (com.apple.developer.family-controls); without it the request fails at runtime.
    public func requestAuthorization() async throws {
        try await AuthorizationCenter.shared.requestAuthorization(for: .child)
    }

    /// Shields the apps whose bundle identifiers appear in `packageIds`.
    public func applyBlockedApps(packageIds: [String]) {
        guard ensureAuthorized(#function) else { return }
        let tokens = TokenResolver.applicationTokens(forBundleIdentifiers: packageIds)
        ManagedSettingsStore().shield.applications = tokens.isEmpty ? nil : tokens
    }

    /// Applies the web filter: `blockedDomains` feed the web-content filter policy while
    /// `blockedCategories` feed the web-domain and application category shields.
    public func applyWebFilter(blockedCategories: [String], blockedDomains: [String]) {
        guard ensureAuthorized(#function) else { return }
        let store = ManagedSettingsStore()
        let domains = Set(blockedDomains.map { WebDomain(domain: $0) })
        store.webContent.blockedByFilter = domains.isEmpty
            ? WebContentSettings.FilterPolicy.none
            : WebContentSettings.FilterPolicy.specific(domains)
        let categories = TokenResolver.categoryTokens(forNames: blockedCategories)
        store.shield.webDomainCategories = categories.isEmpty ? nil : categories
        store.shield.applicationCategories = categories.isEmpty ? nil : categories
    }

    /// Registers a daily repeating bedtime schedule under the activity name `bedtime.<routineID>`.
    public func scheduleBedtime(start: DateComponents, end: DateComponents, routineID: String = "bedtime") throws {
        guard ensureAuthorized(#function) else { return }
        let name = DeviceActivityName("bedtime.\(routineID)")
        // NOTE: DeviceActivitySchedule requires at least hour and minute in the
        // components, and a repeating interval must span at least 15 minutes.
        let schedule = DeviceActivitySchedule(
            intervalStart: start,
            intervalEnd: end,
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

/// Best-effort bridge from rule identifiers (bundle identifiers, category names) to
/// the opaque tokens the Screen Time API requires.
///
/// NOTE: application and category tokens are privacy-preserving; they only materialize
/// for apps and categories that are visible to Screen Time through an authorized
/// FamilyActivityPicker selection (or a persisted copy of one). A production agent
/// should persist the encoded `FamilyActivitySelection` and resolve rules through that
/// registry instead of relying on bundle-record lookups.
enum TokenResolver {

    /// Returns the application tokens for the given bundle identifiers, skipping unresolved ones.
    static func applicationTokens(forBundleIdentifiers bundleIdentifiers: [String]) -> Set<ApplicationToken> {
        Set(bundleIdentifiers.compactMap { Application(bundleIdentifier: $0).token })
    }

    /// Returns the category tokens for the given blocked-category names.
    static func categoryTokens(forNames names: [String]) -> Set<ActivityCategoryToken> {
        // NOTE: no string-based initializer exists for ActivityCategoryToken; map the
        // names through the persisted picker-selection registry once it exists.
        []
    }
}
#endif
