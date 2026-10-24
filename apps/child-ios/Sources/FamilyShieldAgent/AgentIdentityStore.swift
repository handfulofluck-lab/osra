import Foundation

/// Reads and writes the paired [AgentIdentity]. The Device-Activity monitor and Shield extensions run
/// in separate processes, so everything here is shared through the app group
/// (`group.dev.familyshield.agent`):
///
/// - the **secrets**, `deviceToken` and `hmacSecret`, are in the Keychain (`secrets`, an access group
///   shared with the extensions; 5.5 PR B, #372);
/// - the **ids**, `apiBaseURL`, `childId`, `deviceId` and `familyId`, stay in the app-group
///   `UserDefaults`, where `AlertReporter` and the extensions read them. They are not secrets.
///
/// Builds before 5.5 PR B kept the two secrets in that `UserDefaults` too, as plaintext. `load()` moves
/// them into the Keychain the first time it finds them there, then deletes the plaintext copies.
public enum AgentIdentityStore {
    /// Placeholder until the maintainer chooses the permanent app-group id.
    public static let suiteName = "group.dev.familyshield.agent"

    /// Where the secrets live. Tests swap in a store without an access group (an unsigned test bundle has
    /// no entitlements); everything else uses the shared Keychain group.
    public static var secrets: SecretStore = KeychainSecretStore()

    enum Keys {
        static let apiBaseURL = "agent.apiBaseURL"
        static let childId = "agent.childId"
        static let hmacSecret = "agent.hmacSecret"
        static let deviceToken = "agent.deviceToken"
        static let deviceId = "agent.deviceId"
        static let familyId = "agent.familyId"
    }

    /// Persists the identity and returns true on success, or false if the app group suite is unavailable
    /// (IOS-09) or the Keychain refused a secret. A failed save leaves no half-written identity behind.
    @discardableResult
    public static func save(_ identity: AgentIdentity) -> Bool {
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return false
        }
        guard secrets.write(identity.deviceToken, for: Keys.deviceToken) else {
            clear()
            return false
        }
        if let secret = identity.hmacSecret, !secret.isEmpty {
            guard secrets.write(secret, for: Keys.hmacSecret) else {
                clear()
                return false
            }
        } else {
            secrets.delete(Keys.hmacSecret)
        }
        defaults.set(identity.apiBaseURL.absoluteString, forKey: Keys.apiBaseURL)
        defaults.set(identity.childId, forKey: Keys.childId)
        defaults.set(identity.deviceId, forKey: Keys.deviceId)
        defaults.set(identity.familyId, forKey: Keys.familyId)
        // No plaintext copy of a secret survives a save, whatever an older build left behind.
        defaults.removeObject(forKey: Keys.deviceToken)
        defaults.removeObject(forKey: Keys.hmacSecret)
        return true
    }

    /// Returns the persisted identity, or nil when the device has not been paired.
    public static func load() -> AgentIdentity? {
        migrateLegacySecrets()
        let defaults = UserDefaults(suiteName: suiteName)
        guard let base = defaults?.string(forKey: Keys.apiBaseURL),
              let url = URL(string: base),
              let token = secrets.read(Keys.deviceToken), !token.isEmpty,
              let childId = defaults?.string(forKey: Keys.childId), !childId.isEmpty
        else { return nil }
        return AgentIdentity(
            apiBaseURL: url,
            deviceToken: token,
            deviceId: defaults?.string(forKey: Keys.deviceId) ?? "",
            childId: childId,
            familyId: defaults?.string(forKey: Keys.familyId) ?? "",
            hmacSecret: hmacSecret()
        )
    }

    /// The pairing HMAC secret, if any. Read by `AlertReporter` in the app and the extensions.
    public static func hmacSecret() -> String? {
        migrateLegacySecrets()
        let secret = secrets.read(Keys.hmacSecret)
        return (secret?.isEmpty == false) ? secret : nil
    }

    /// True when a pairing identity exists.
    public static func isPaired() -> Bool { load() != nil }

    /// Clears the identity (re-pair flow). Rules/keys written by other components
    /// (bedtime bundle ids, blocked apps) are left untouched.
    public static func clear() {
        secrets.delete(Keys.deviceToken)
        secrets.delete(Keys.hmacSecret)
        guard let defaults = UserDefaults(suiteName: suiteName) else { return }
        for key in [Keys.apiBaseURL, Keys.childId, Keys.hmacSecret, Keys.deviceToken, Keys.deviceId, Keys.familyId] {
            defaults.removeObject(forKey: key)
        }
    }

    /// Moves secrets an older build left in app-group `UserDefaults` into the Keychain. A plaintext copy
    /// is deleted only once the Keychain holds it, so a refused write loses nothing and is retried on the
    /// next read. A secret already in the Keychain wins over a stale plaintext copy, which is just deleted.
    static func migrateLegacySecrets() {
        guard let defaults = UserDefaults(suiteName: suiteName) else { return }
        for key in [Keys.deviceToken, Keys.hmacSecret] {
            guard let legacy = defaults.string(forKey: key) else { continue }
            if legacy.isEmpty || secrets.read(key) != nil || secrets.write(legacy, for: key) {
                defaults.removeObject(forKey: key)
            }
        }
    }
}
