import Foundation
#if os(iOS)
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
}

#if os(iOS)
extension ShieldSet {
    var name: ManagedSettingsStore.Name { ManagedSettingsStore.Name(rawValue) }

    var store: ManagedSettingsStore { ManagedSettingsStore(named: name) }
}
#endif

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
        let store = set.store
        store.shield.applicationCategories = .all()
        store.shield.webDomainCategories = .all()
        // `ManagedSettingsStore` writes do not throw, so the only honest ack is a read-back. A store that did
        // not take the policy reports the failure rather than claiming a lock the child never saw.
        return store.shield.applicationCategories != nil ? .applied : .failed("shield_not_applied")
    }

    public func unshield(_ set: ShieldSet) async -> ShieldOutcome {
        let store = set.store
        store.clearAllSettings()
        // Clears every field of this store only; the child's own rules and the other store are untouched.
        return store.shield.applicationCategories == nil ? .cleared : .failed("shield_still_applied")
    }

    #else
    // ManagedSettings exists only on iOS; the macOS build (package tests) never writes a real store.
    public func shield(_ set: ShieldSet) async -> ShieldOutcome { .failed("shield_unavailable") }

    public func unshield(_ set: ShieldSet) async -> ShieldOutcome { .failed("shield_unavailable") }
    #endif
}
