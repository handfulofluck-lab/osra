import Foundation

/// Reads and writes the paired [AgentIdentity] in the shared app group
/// (`group.dev.familyshield.agent`). The Device-Activity monitor and Shield
/// extensions run in separate processes, so pairing state must live in the
/// app group — `AlertReporter` reads `agent.childId`, `agent.hmacSecret` and
/// `agent.apiBaseURL` from exactly these keys.
///
/// NOTE (security): UserDefaults app-group storage is plaintext and only
/// acceptable for a test build. Before shipping, move `deviceToken` and
/// `hmacSecret` into the Keychain (kSecAttrAccessGroup = the app group) and
/// keep only the non-secret ids here; AlertReporter must then read the
/// secrets from Keychain. Tracked in the review handoff (token hygiene).
public enum AgentIdentityStore {
    /// Placeholder until the Xcode project defines the real app-group id.
    public static let suiteName = "group.dev.familyshield.agent"

    enum Keys {
        static let apiBaseURL = "agent.apiBaseURL"
        static let childId = "agent.childId"
        static let hmacSecret = "agent.hmacSecret"
        static let deviceToken = "agent.deviceToken"
        static let deviceId = "agent.deviceId"
        static let familyId = "agent.familyId"
    }

    /// Persists the identity and force-syncs so extension processes see it immediately.
    public static func save(_ identity: AgentIdentity) {
        let defaults = UserDefaults(suiteName: suiteName)
        defaults?.set(identity.apiBaseURL.absoluteString, forKey: Keys.apiBaseURL)
        defaults?.set(identity.childId, forKey: Keys.childId)
        defaults?.set(identity.deviceToken, forKey: Keys.deviceToken)
        defaults?.set(identity.deviceId, forKey: Keys.deviceId)
        defaults?.set(identity.familyId, forKey: Keys.familyId)
        if let secret = identity.hmacSecret, !secret.isEmpty {
            defaults?.set(secret, forKey: Keys.hmacSecret)
        } else {
            defaults?.removeObject(forKey: Keys.hmacSecret)
        }
        defaults?.synchronize()
    }

    /// Returns the persisted identity, or nil when the device has not been paired.
    public static func load() -> AgentIdentity? {
        let defaults = UserDefaults(suiteName: suiteName)
        guard let base = defaults?.string(forKey: Keys.apiBaseURL),
              let url = URL(string: base),
              let token = defaults?.string(forKey: Keys.deviceToken), !token.isEmpty,
              let childId = defaults?.string(forKey: Keys.childId), !childId.isEmpty
        else { return nil }
        let secret = defaults?.string(forKey: Keys.hmacSecret)
        return AgentIdentity(
            apiBaseURL: url,
            deviceToken: token,
            deviceId: defaults?.string(forKey: Keys.deviceId) ?? "",
            childId: childId,
            familyId: defaults?.string(forKey: Keys.familyId) ?? "",
            hmacSecret: (secret?.isEmpty == false) ? secret : nil
        )
    }

    /// True when a pairing identity exists.
    public static func isPaired() -> Bool { load() != nil }

    /// Clears the identity (re-pair flow). Rules/keys written by other components
    /// (bedtime bundle ids, blocked apps) are left untouched.
    public static func clear() {
        let defaults = UserDefaults(suiteName: suiteName)
        for key in [Keys.apiBaseURL, Keys.childId, Keys.hmacSecret, Keys.deviceToken, Keys.deviceId, Keys.familyId] {
            defaults?.removeObject(forKey: key)
        }
        defaults?.synchronize()
    }
}
