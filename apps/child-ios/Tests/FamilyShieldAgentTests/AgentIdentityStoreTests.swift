import XCTest
@testable import FamilyShieldAgent

/// 5.5 PR B (#372): the device token and the HMAC secret go to the `SecretStore` (the Keychain in the
/// app), never to app-group `UserDefaults`, and an older build's plaintext copies move across.
///
/// This SwiftPM test bundle is unsigned, so the simulator Keychain refuses it (errSecMissingEntitlement,
/// -34018). The logic is tested here against an in-memory store; `HostedTests/KeychainTests.swift` runs
/// the real `KeychainSecretStore` inside the signed simulator app, with the shared access group.
final class AgentIdentityStoreTests: XCTestCase {

    private let store = InMemorySecretStore()
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
        AgentIdentityStore.secrets = store
        AgentIdentityStore.clear()
    }

    override func tearDown() {
        AgentIdentityStore.clear()
        super.tearDown()
    }

    // MARK: - Where each field goes

    func testSaveKeepsSecretsOutOfUserDefaults() {
        XCTAssertTrue(AgentIdentityStore.save(identity))
        XCTAssertEqual(store.read(AgentIdentityStore.Keys.deviceToken), "device-jwt")
        XCTAssertEqual(store.read(AgentIdentityStore.Keys.hmacSecret), "hmac-secret")
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
        XCTAssertNil(store.read(AgentIdentityStore.Keys.hmacSecret))
        XCTAssertEqual(AgentIdentityStore.load(), noSecret)
    }

    func testClearRemovesTheSecrets() {
        XCTAssertTrue(AgentIdentityStore.save(identity))
        AgentIdentityStore.clear()
        XCTAssertNil(store.read(AgentIdentityStore.Keys.deviceToken))
        XCTAssertNil(store.read(AgentIdentityStore.Keys.hmacSecret))
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
        XCTAssertEqual(store.read(AgentIdentityStore.Keys.deviceToken), "device-jwt")
        XCTAssertEqual(store.read(AgentIdentityStore.Keys.hmacSecret), "hmac-secret")
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
        AgentIdentityStore.secrets = store
    }
}

/// The `SecretStore` contract, in memory.
final class InMemorySecretStore: SecretStore {
    private var values: [String: String] = [:]
    func read(_ account: String) -> String? { values[account] }
    func write(_ value: String, for account: String) -> Bool { values[account] = value; return true }
    func delete(_ account: String) { values[account] = nil }
}

/// A store that refuses every write, as a Keychain does when the item cannot be stored.
private struct RefusingSecretStore: SecretStore {
    func read(_ account: String) -> String? { nil }
    func write(_ value: String, for account: String) -> Bool { false }
    func delete(_ account: String) {}
}
