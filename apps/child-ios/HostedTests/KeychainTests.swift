import XCTest
import Security
@testable import FamilyShieldAgent

/// 5.5 PR B (#372): the real Keychain, inside the simulator app (`OSRAAgentHostedTests`, hosted by
/// `OSRAAgent`). The app is ad-hoc signed for the simulator with its own entitlements, so these use the
/// production access group, `group.dev.familyshield.agent`, the one the extensions share. The unsigned
/// SwiftPM test bundle cannot reach the Keychain at all (-34018); its logic tests use an in-memory store.
final class KeychainTests: XCTestCase {

    private let keychain = KeychainSecretStore()
    private let defaults = UserDefaults(suiteName: AgentIdentityStore.suiteName)!

    override func setUp() {
        super.setUp()
        AgentIdentityStore.secrets = keychain
        AgentIdentityStore.clear()
        keychain.delete("test.account")
    }

    override func tearDown() {
        AgentIdentityStore.clear()
        keychain.delete("test.account")
        super.tearDown()
    }

    func testUsesTheSharedAppGroupAccessGroup() {
        XCTAssertEqual(keychain.accessGroup, "group.dev.familyshield.agent")
    }

    func testWriteReadOverwriteDelete() {
        XCTAssertNil(keychain.read("test.account"))
        XCTAssertTrue(keychain.write("first", for: "test.account"))
        XCTAssertEqual(keychain.read("test.account"), "first")
        XCTAssertTrue(keychain.write("second", for: "test.account"), "a second write updates the item")
        XCTAssertEqual(keychain.read("test.account"), "second")
        keychain.delete("test.account")
        XCTAssertNil(keychain.read("test.account"))
        keychain.delete("test.account") // deleting what is not there is not an error
    }

    /// The item as the Keychain stored it: one item, in the shared group, readable after first unlock,
    /// and never migrated off this device.
    func testItemIsThisDeviceOnlyInTheSharedGroup() throws {
        XCTAssertTrue(keychain.write("value", for: "test.account"))
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainSecretStore.service,
            kSecAttrAccount as String: "test.account",
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, &result), errSecSuccess)
        let items = try XCTUnwrap(result as? [[String: Any]])
        XCTAssertEqual(items.count, 1, "a second write must not leave a duplicate item")
        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(item[kSecAttrAccessible as String] as? String, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        XCTAssertEqual(item[kSecAttrAccessGroup as String] as? String, "group.dev.familyshield.agent")
    }

    func testIdentityRoundTripsWithSecretsInTheKeychainOnly() {
        let identity = AgentIdentity(
            apiBaseURL: URL(string: "https://api.example.invalid")!,
            deviceToken: "device-jwt",
            deviceId: "dev-1",
            childId: "child-1",
            familyId: "fam-1",
            hmacSecret: "hmac-secret"
        )
        XCTAssertTrue(AgentIdentityStore.save(identity))
        XCTAssertEqual(keychain.read(AgentIdentityStore.Keys.deviceToken), "device-jwt")
        XCTAssertNil(defaults.string(forKey: AgentIdentityStore.Keys.deviceToken))
        XCTAssertNil(defaults.string(forKey: AgentIdentityStore.Keys.hmacSecret))
        XCTAssertEqual(AgentIdentityStore.load(), identity)
        AgentIdentityStore.clear()
        XCTAssertNil(keychain.read(AgentIdentityStore.Keys.deviceToken))
        XCTAssertNil(keychain.read(AgentIdentityStore.Keys.hmacSecret))
    }

    /// A reinstall keeps the Keychain but not the app group: the launch-time clean-up removes the old items.
    func testSecretsWithoutAnIdentityAreClearedAtLaunch() {
        XCTAssertTrue(keychain.write("old-jwt", for: AgentIdentityStore.Keys.deviceToken))
        XCTAssertTrue(keychain.write("old-hmac", for: AgentIdentityStore.Keys.hmacSecret))
        XCTAssertTrue(AgentIdentityStore.clearOrphanedSecrets())
        XCTAssertNil(keychain.read(AgentIdentityStore.Keys.deviceToken))
        XCTAssertNil(keychain.read(AgentIdentityStore.Keys.hmacSecret))
    }

    func testOlderBuildsPlaintextSecretsMoveIntoTheKeychain() {
        defaults.set("https://api.example.invalid", forKey: AgentIdentityStore.Keys.apiBaseURL)
        defaults.set("child-1", forKey: AgentIdentityStore.Keys.childId)
        defaults.set("device-jwt", forKey: AgentIdentityStore.Keys.deviceToken)
        defaults.set("hmac-secret", forKey: AgentIdentityStore.Keys.hmacSecret)
        XCTAssertEqual(AgentIdentityStore.load()?.deviceToken, "device-jwt")
        XCTAssertEqual(keychain.read(AgentIdentityStore.Keys.hmacSecret), "hmac-secret")
        XCTAssertNil(defaults.string(forKey: AgentIdentityStore.Keys.deviceToken))
        XCTAssertNil(defaults.string(forKey: AgentIdentityStore.Keys.hmacSecret))
    }
}
