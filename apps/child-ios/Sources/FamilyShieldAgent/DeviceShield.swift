import Foundation
#if os(iOS)
import DeviceActivity
import ManagedSettings
#endif

/// #1089: the two Screen Time stores a parent command can switch on an iPhone child.
///
/// `lock` and `pause` share the lock store, so a parent who pauses a device and later unlocks it cannot leave
/// a half-shielded phone behind. `pause_internet` gets its own store, so resuming the internet never lifts a
/// lock, and unlocking never resumes the internet — each command clears only what it set.
///
/// Both shield **everything**: every app category and every web domain. iOS cannot cut the network itself, so
/// "pause internet" is honestly "apps and websites", which is the copy the parent screen carries. The OSRA
/// app is shielded too, on purpose: the parent's Unlock and Resume arrive by push and still wake the app
/// (Apple's own Lock behaves the same way), and a shield with an exception list is a promise the app cannot
/// keep without application tokens it does not have.
public enum ShieldSet: String, CaseIterable, Equatable, Sendable {
    case lock = "osraLock"
    case internet = "osraPauseInternet"

    /// The longest a parent command's shield lasts on an iPhone before it lifts by itself (Ahmed, #1275).
    ///
    /// A child who force-quits OSRA under a lock cannot relaunch it (the shield covers OSRA too), and iOS does
    /// not wake a force-quit app for a push, so a parent's Unlock could never arrive. The safety net is a
    /// one-off `DeviceActivity` interval named after the store: when it ends, the monitor extension clears that
    /// store (`FamilyShieldDeviceActivityMonitor.intervalDidEnd` already clears the store named after the
    /// activity, and `ShieldPolicy` applies nothing when it starts). The extension runs whatever state the app
    /// is in. Each new Lock restarts the interval; Unlock and Resume stop it.
    /// 8 hours: Karim's decision, 27 Nov 20:50 UAE ("lets make it 8 hours then not 2").
    public static let failsafeSeconds: TimeInterval = 8 * 60 * 60
}

#if os(iOS)
extension ShieldSet {
    var name: ManagedSettingsStore.Name { ManagedSettingsStore.Name(rawValue) }

    var store: ManagedSettingsStore { ManagedSettingsStore(named: name) }
}
#endif

extension ShieldSet {
    /// osra-security#93: a parent's Lock or Pause belongs to one pairing. Consent withdrawal, revocation and a
    /// new pairing clear both command stores, so a lock never outlives the relationship that set it. Ordinary
    /// Unlock and Resume still clear only their own store. The package tests replace this.
    public static var clearAllStores: () -> Void = {
        #if os(iOS)
        for set in ShieldSet.allCases { set.store.clearAllSettings() }
        #endif
    }
}

/// What one write to a Screen Time store did. `failed` carries the server-side reason, never a bare `false`:
/// the parent panel shows it in Delivery status, and a silent failure is the bug #1089 exists to end.
public enum ShieldOutcome: Equatable, Sendable {
    case applied
    case cleared
    case failed(String)
}

/// A parent command's effect on one store. Injectable so the drainer's tests need no Screen Time: the live
/// implementation writes `ManagedSettingsStore`, the fake records calls.
public protocol DeviceShielding: Sendable {
    func shield(_ set: ShieldSet) async -> ShieldOutcome
    func unshield(_ set: ShieldSet) async -> ShieldOutcome
}

public struct LiveDeviceShield: DeviceShielding {
    public init() {}

    #if os(iOS)
    public func shield(_ set: ShieldSet) async -> ShieldOutcome {
        // The safety net first: a shield that cannot lift by itself is never applied (Ahmed, #1275).
        guard Self.startFailsafe(for: set) else { return .failed("failsafe_not_scheduled") }
        let store = set.store
        store.shield.applicationCategories = .all()
        store.shield.webDomainCategories = .all()
        // `ManagedSettingsStore` writes do not throw, so the only honest ack is a read-back. A store that did
        // not take the policy reports the failure rather than claiming a lock the child never saw.
        // Both halves must read back: an apps-only shield would still let the child browse.
        let applied = store.shield.applicationCategories != nil && store.shield.webDomainCategories != nil
        return applied ? .applied : .failed("shield_not_applied")
    }

    public func unshield(_ set: ShieldSet) async -> ShieldOutcome {
        let store = set.store
        store.clearAllSettings()
        // Clears every field of this store only; the child's own rules and the other store are untouched.
        let cleared = store.shield.applicationCategories == nil && store.shield.webDomainCategories == nil
        // The safety interval stops only once the readback proves the store is clear (Codex, #1275): a failed
        // clear keeps the automatic lift as the way out.
        guard cleared else { return .failed("shield_still_applied") }
        DeviceActivityCenter().stopMonitoring([DeviceActivityName(set.rawValue)])
        return .cleared
    }

    /// Starts (or restarts) the one-off interval whose end lifts this store's shield. False when iOS refuses
    /// it, so the caller can refuse the shield rather than risk a lock with no way out.
    private static func startFailsafe(for set: ShieldSet, now: Date = Date()) -> Bool {
        let calendar = Calendar.current
        let fields: Set<Calendar.Component> = [.year, .month, .day, .hour, .minute, .second]
        let schedule = DeviceActivitySchedule(
            intervalStart: calendar.dateComponents(fields, from: now),
            intervalEnd: calendar.dateComponents(fields, from: now.addingTimeInterval(ShieldSet.failsafeSeconds)),
            repeats: false
        )
        // No stopMonitoring first: starting the same name replaces its schedule, and a stop here could race an
        // interval end that clears the store this Lock is about to write.
        do {
            try DeviceActivityCenter().startMonitoring(DeviceActivityName(set.rawValue), during: schedule)
            return true
        } catch {
            return false
        }
    }

    #else
    // ManagedSettings exists only on iOS; the macOS build (package tests) never writes a real store.
    public func shield(_ set: ShieldSet) async -> ShieldOutcome { .failed("shield_unavailable") }

    public func unshield(_ set: ShieldSet) async -> ShieldOutcome { .failed("shield_unavailable") }
    #endif
}
