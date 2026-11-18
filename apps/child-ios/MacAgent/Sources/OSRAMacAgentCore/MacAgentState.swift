import Foundation
import FamilyShieldAgent

/// The few things the daemon keeps beside the shared identity and rule stores, in the same root-owned
/// preferences (`/var/root/Library/Preferences`, which a standard user cannot read). None is a secret.
public enum MacAgentState {
    enum Keys {
        static let childUser = "mac.childUser"
        static let rulesVersion = "mac.rulesVersion"
    }

    private static var defaults: UserDefaults? { UserDefaults(suiteName: AgentIdentityStore.suiteName) }

    /// The child's macOS account name, given at pairing; nil when the parent did not say. It stays on this Mac:
    /// it is never logged and never sent.
    public static func childUser() -> String? { defaults?.string(forKey: Keys.childUser) }

    public static func setChildUser(_ name: String?) {
        if let name { defaults?.set(name, forKey: Keys.childUser) } else { defaults?.removeObject(forKey: Keys.childUser) }
    }

    /// The version of the rules stored by the last sync; nil before the first one.
    public static func rulesVersion() -> Int? {
        guard let defaults, defaults.object(forKey: Keys.rulesVersion) != nil else { return nil }
        return defaults.integer(forKey: Keys.rulesVersion)
    }

    public static func setRulesVersion(_ version: Int?) {
        if let version { defaults?.set(version, forKey: Keys.rulesVersion) } else { defaults?.removeObject(forKey: Keys.rulesVersion) }
    }

    public static func clear() {
        setChildUser(nil)
        setRulesVersion(nil)
    }
}
