import Foundation
import os
import Security

/// Where the agent keeps its two secrets: the device JWT and the per-device HMAC secret (5.5 PR B, #372).
///
/// The app and its three extensions run in separate processes, so the secrets must be readable by all
/// four. The Keychain does that through a shared access group; plain app-group `UserDefaults` did it
/// too, but as a plaintext plist inside the container, included in backups.
public protocol SecretStore {
    /// The stored value, or nil when there is none (or the store cannot be read).
    func read(_ account: String) -> String?
    /// Stores the value, replacing any previous one; false when the store refused it.
    @discardableResult func write(_ value: String, for account: String) -> Bool
    /// Removes the value; removing a value that is not there is not an error.
    func delete(_ account: String)
}

/// Generic-password items in the Keychain, one per account, under one service.
///
/// - The access group is the app group `group.dev.familyshield.agent`: on iOS an app group the target is
///   entitled to is also a Keychain access group, so the monitor and shield extensions read the items the
///   app writes without a separate `keychain-access-groups` entitlement. `nil` uses the caller's default
///   group (the unsigned XCTest bundle has no entitlements, so the tests use that).
/// - Accessibility is `AfterFirstUnlockThisDeviceOnly`: the extensions run in the background while the
///   phone is locked, which rules out `WhenUnlocked`, and `ThisDeviceOnly` keeps the secrets out of
///   backups and off any other device a backup is restored to. A restored phone re-pairs.
public struct KeychainSecretStore: SecretStore {
    public static let service = "dev.familyshield.agent"

    private static let logger = Logger(subsystem: "dev.familyshield.agent", category: "Keychain")

    public let accessGroup: String?

    public init(accessGroup: String? = AgentIdentityStore.suiteName) {
        self.accessGroup = accessGroup
    }

    private func query(_ account: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }

    public func read(_ account: String) -> String? {
        var request = query(account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            if status != errSecItemNotFound {
                Self.logger.error("keychain read of \(account, privacy: .public) failed: \(status)")
            }
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    public func write(_ value: String, for account: String) -> Bool {
        let data = Data(value.utf8)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        var status = SecItemUpdate(query(account) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query(account).merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        if status != errSecSuccess {
            Self.logger.error("keychain write of \(account, privacy: .public) failed: \(status)")
        }
        return status == errSecSuccess
    }

    public func delete(_ account: String) {
        let status = SecItemDelete(query(account) as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            Self.logger.error("keychain delete of \(account, privacy: .public) failed: \(status)")
        }
    }
}
