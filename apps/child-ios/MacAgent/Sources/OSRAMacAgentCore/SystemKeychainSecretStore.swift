import Foundation
import os
import Security
import FamilyShieldAgent

/// Where the daemon keeps the device token and the HMAC secret: the **System keychain**
/// (`/Library/Keychains/System.keychain`), the one a root daemon can use with no user logged in (#775).
///
/// Why a standard user cannot read them:
/// - the items carry the default access list, which trusts only the program that stored them (`osra-agent`,
///   run as root); any other program has to ask, and for the System keychain that question needs an
///   administrator's name and password, which the child does not have (ADR-0036 rule 4);
/// - this store never answers such a question itself: `forbidPrompts()` makes a read that would need one fail.
///
/// The keychain is always named explicitly. A root process started with `sudo` from a user's Terminal has that
/// user's keychain list, and "the default keychain" there could be a login keychain; a secret must never land
/// in one. When the System keychain cannot be opened, every call fails closed.
///
/// The file-based keychain calls are deprecated in favour of the data protection keychain, which a daemon
/// outside a login session cannot use. They are the supported way to reach the System keychain.
public struct SystemKeychainSecretStore: SecretStore {
    public static let service = "com.osratech.agent"
    public static let systemKeychainPath = "/Library/Keychains/System.keychain"

    private static let logger = Logger(subsystem: "com.osratech.agent", category: "Keychain")

    private let keychain: SecKeychain?

    /// The System keychain.
    public init() {
        var opened: SecKeychain?
        let status = SecKeychainOpen(Self.systemKeychainPath, &opened)
        if status != errSecSuccess { Self.logger.error("system keychain could not be opened: \(status)") }
        keychain = status == errSecSuccess ? opened : nil
    }

    /// A given keychain; the tests use a throwaway one.
    public init(keychain: SecKeychain) {
        self.keychain = keychain
    }

    /// The daemon has nobody to ask: a read that would put up a password dialog fails instead. Process-wide.
    public static func forbidPrompts() {
        SecKeychainSetUserInteractionAllowed(false)
    }

    private func item(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
        ]
    }

    private func search(_ account: String, in keychain: SecKeychain) -> [String: Any] {
        var query = item(account)
        query[kSecMatchSearchList as String] = [keychain]
        return query
    }

    public func read(_ account: String) -> String? {
        guard let keychain else { return nil }
        var request = search(account, in: keychain)
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
        guard let keychain else { return false }
        let data = Data(value.utf8)
        var status = SecItemUpdate(search(account, in: keychain) as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = item(account)
            add[kSecUseKeychain as String] = keychain
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "OSRA Agent"
            status = SecItemAdd(add as CFDictionary, nil)
        }
        if status != errSecSuccess {
            Self.logger.error("keychain write of \(account, privacy: .public) failed: \(status)")
        }
        return status == errSecSuccess
    }

    public func delete(_ account: String) {
        guard let keychain else { return }
        let status = SecItemDelete(search(account, in: keychain) as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            Self.logger.error("keychain delete of \(account, privacy: .public) failed: \(status)")
        }
    }

    /// Stores, reads back and removes a throwaway item. Pairing runs it first, so a Mac whose keychain refuses
    /// the daemon fails before the pairing code is spent, not after the server has made the device.
    public func selfTest() -> Bool {
        let account = "agent.selfTest"
        let value = UUID().uuidString
        defer { delete(account) }
        return write(value, for: account) && read(account) == value
    }
}
