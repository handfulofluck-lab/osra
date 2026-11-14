import XCTest
import Security
import FamilyShieldAgent
@testable import OSRAMacAgentCore

/// The store against a real file-based keychain: a throwaway one made for the test, the same kind as the System
/// keychain. Writing to the System keychain itself needs root, so that row is run on the test Mac (README).
final class SystemKeychainSecretStoreTests: XCTestCase {

    private var keychain: SecKeychain!
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("osra-agent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let password = Array(UUID().uuidString.utf8)
        var created: SecKeychain?
        let status = SecKeychainCreate(directory.appendingPathComponent("test.keychain").path,
                                       UInt32(password.count), password, false, nil, &created)
        XCTAssertEqual(status, errSecSuccess, "a throwaway keychain could not be made")
        keychain = try XCTUnwrap(created)
    }

    override func tearDownWithError() throws {
        if let keychain { SecKeychainDelete(keychain) }
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    // Mutant: a write that does not reach the keychain, or a read from some other keychain.
    func testWritesReadsReplacesAndDeletes() {
        let store = SystemKeychainSecretStore(keychain: keychain)
        XCTAssertNil(store.read("agent.deviceToken"))
        XCTAssertTrue(store.write("first", for: "agent.deviceToken"))
        XCTAssertTrue(store.write("hmac", for: "agent.hmacSecret"))
        XCTAssertEqual(store.read("agent.deviceToken"), "first")
        XCTAssertTrue(store.write("second", for: "agent.deviceToken"), "a second write replaces, it does not fail as a duplicate")
        XCTAssertEqual(store.read("agent.deviceToken"), "second")
        XCTAssertEqual(store.read("agent.hmacSecret"), "hmac")
        store.delete("agent.deviceToken")
        XCTAssertNil(store.read("agent.deviceToken"))
        XCTAssertEqual(store.read("agent.hmacSecret"), "hmac", "deleting one account leaves the other")
        store.delete("agent.deviceToken") // deleting what is not there is not an error
        XCTAssertTrue(store.selfTest())
        XCTAssertNil(store.read("agent.selfTest"), "the self-test leaves nothing behind")
    }

    // Mutant: falling back to the default keychain. The item must be in the named keychain and nowhere else: a
    // search of the user's own keychain list must not find it.
    func testTheSecretIsOnlyInTheNamedKeychain() {
        let store = SystemKeychainSecretStore(keychain: keychain)
        let account = "agent.test.\(UUID().uuidString)"
        XCTAssertTrue(store.write("value", for: account))
        let anywhereElse: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: SystemKeychainSecretStore.service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        XCTAssertNotEqual(SecItemCopyMatching(anywhereElse as CFDictionary, nil), errSecSuccess)
        store.delete(account)
    }

    // The shared identity store on top of this one: what pairing saves is what the daemon loads.
    func testTheSharedIdentityStoreRoundTripsThroughIt() {
        let previous = AgentIdentityStore.secrets
        defer { AgentIdentityStore.clear(); AgentIdentityStore.secrets = previous }
        AgentIdentityStore.secrets = SystemKeychainSecretStore(keychain: keychain)
        let identity = AgentIdentity(apiBaseURL: MacAgentServer.builtIn, deviceToken: "jwt", deviceId: "dev-1",
                                     childId: "child-1", familyId: "fam-1", hmacSecret: "hmac")
        XCTAssertTrue(AgentIdentityStore.saveNewPairing(identity))
        XCTAssertEqual(AgentRuntime.loadIdentity(), identity)
        AgentIdentityStore.clear()
        XCTAssertNil(AgentRuntime.loadIdentity())
        XCTAssertNil(SystemKeychainSecretStore(keychain: keychain).read("agent.deviceToken"))
    }
}
