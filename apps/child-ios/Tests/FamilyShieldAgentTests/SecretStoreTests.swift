import XCTest
@testable import FamilyShieldAgent

/// 5.5 PR B (#372): the device token and the HMAC secret live in the Keychain, not in app-group
/// `UserDefaults`. These run against the real simulator Keychain. The unsigned test bundle has no
/// entitlements, so the store uses the bundle's default access group (`accessGroup: nil`); the shared
/// group the app and its extensions use is a signing matter, checked on a signed build (5.1).
final class SecretStoreTests: XCTestCase {

    private let keychain = KeychainSecretStore(accessGroup: nil)
    private let defaults = UserDefaults(suiteName: AgentIdentityStore.suiteName)!
    private let identity = AgentIdentity(
        apiBaseURL: URL(string: "https://api.example.invalid")!,
        deviceToken: "device-jwt",
        deviceId: "dev-1",
        childId: "child-1",
        familyId: "fam-1",
        hmacSecret: "hmac-secret"
    )

    override func setUp() {
        super.setUp()
        AgentIdentityStore.secrets = keychain
        AgentIdentityStore.clear()
    }

    override func tearDown() {
        AgentIdentityStore.clear()
        super.tearDown()
    }

    // MARK: - KeychainSecretStore

    func testKeychainWriteReadOverwriteDelete() {
        XCTAssertNil(keychain.read("test.account"))
        XCTAssertTrue(keychain.write("first", for: "test.account"))
        XCTAssertEqual(keychain.read("test.account"), "first")
        XCTAssertTrue(keychain.write("second", for: "test.account"), "a second write updates, not duplicates")
        XCTAssertEqual(keychain.read("test.account"), "second")
        keychain.delete("test.account")
        XCTAssertNil(keychain.read("test.account"))
        keychain.delete("test.account") // deleting what is not there is not an error
    }

    // MARK: - AgentIdentityStore on the Keychain

    func testSaveKeepsSecretsOutOfUserDefaults() {
        XCTAssertTrue(AgentIdentityStore.save(identity))
        XCTAssertEqual(keychain.read(AgentIdentityStore.Keys.deviceToken), "device-jwt")
        XCTAssertEqual(keychain.read(AgentIdentityStore.Keys.hmacSecret), "hmac-secret")
        XCTAssertNil(defaults.string(forKey: AgentIdentityStore.Keys.deviceToken))
        XCTAssertNil(defaults.string(forKey: AgentIdentityStore.Keys.hmacSecret))
        // The ids stay in the app group, where the extensions read them.
        XCTAssertEqual(defaults.string(forKey: AgentIdentityStore.Keys.childId), "child-1")
        XCTAssertEqual(AgentIdentityStore.load(), identity)
        XCTAssertEqual(AgentIdentityStore.hmacSecret(), "hmac-secret")
        XCTAssertEqual(AlertReporter.pairedHmacSecret(), "hmac-secret")
    }

    func testSaveWithoutHmacSecretRemovesAnOldOne() {
        XCTAssertTrue(AgentIdentityStore.save(identity))
        var noSecret = identity
        noSecret.hmacSecret = nil
        XCTAssertTrue(AgentIdentityStore.save(noSecret))
        XCTAssertNil(keychain.read(AgentIdentityStore.Keys.hmacSecret))
        XCTAssertEqual(AgentIdentityStore.load(), noSecret)
    }

    func testClearRemovesSecretsFromTheKeychain() {
        XCTAssertTrue(AgentIdentityStore.save(identity))
        AgentIdentityStore.clear()
        XCTAssertNil(keychain.read(AgentIdentityStore.Keys.deviceToken))
        XCTAssertNil(keychain.read(AgentIdentityStore.Keys.hmacSecret))
        XCTAssertNil(AgentIdentityStore.load())
        XCTAssertFalse(AgentIdentityStore.isPaired())
    }

    // MARK: - Migration from the plaintext keys of older builds

    /// What a build before 5.5 PR B left behind: every field, secrets included, in app-group UserDefaults.
    private func writeLegacyIdentity() {
        defaults.set(identity.apiBaseURL.absoluteString, forKey: AgentIdentityStore.Keys.apiBaseURL)
        defaults.set(identity.childId, forKey: AgentIdentityStore.Keys.childId)
        defaults.set(identity.deviceId, forKey: AgentIdentityStore.Keys.deviceId)
        defaults.set(identity.familyId, forKey: AgentIdentityStore.Keys.familyId)
        defaults.set("device-jwt", forKey: AgentIdentityStore.Keys.deviceToken)
        defaults.set("hmac-secret", forKey: AgentIdentityStore.Keys.hmacSecret)
    }

    func testLoadMigratesLegacySecretsAndDeletesThePlaintext() {
        writeLegacyIdentity()
        XCTAssertEqual(AgentIdentityStore.load(), identity, "a phone paired by an older build stays paired")
        XCTAssertEqual(keychain.read(AgentIdentityStore.Keys.deviceToken), "device-jwt")
        XCTAssertEqual(keychain.read(AgentIdentityStore.Keys.hmacSecret), "hmac-secret")
        XCTAssertNil(defaults.string(forKey: AgentIdentityStore.Keys.deviceToken))
        XCTAssertNil(defaults.string(forKey: AgentIdentityStore.Keys.hmacSecret))
    }

    func testExtensionReadOfTheSecretAlsoMigrates() {
        // The monitor extension may run before the app opens after an update.
        writeLegacyIdentity()
        XCTAssertEqual(AlertReporter.pairedHmacSecret(), "hmac-secret")
        XCTAssertNil(defaults.string(forKey: AgentIdentityStore.Keys.hmacSecret))
    }

    func testKeychainValueWinsOverAStalePlaintextCopy() {
        XCTAssertTrue(AgentIdentityStore.save(identity))
        defaults.set("stale-secret", forKey: AgentIdentityStore.Keys.hmacSecret)
        XCTAssertEqual(AgentIdentityStore.hmacSecret(), "hmac-secret")
        XCTAssertNil(defaults.string(forKey: AgentIdentityStore.Keys.hmacSecret))
    }

    func testRefusedKeychainWriteKeepsThePlaintextForTheNextTry() {
        AgentIdentityStore.secrets = RefusingSecretStore()
        writeLegacyIdentity()
        XCTAssertNil(AgentIdentityStore.load())
        XCTAssertEqual(defaults.string(forKey: AgentIdentityStore.Keys.deviceToken), "device-jwt",
                       "nothing is deleted until the Keychain holds it")
        XCTAssertFalse(AgentIdentityStore.save(identity), "a save the Keychain refuses reports failure")
        AgentIdentityStore.secrets = keychain
    }
}

/// A store that refuses every write, as a Keychain does when the item cannot be stored.
private struct RefusingSecretStore: SecretStore {
    func read(_ account: String) -> String? { nil }
    func write(_ value: String, for account: String) -> Bool { false }
    func delete(_ account: String) {}
}
