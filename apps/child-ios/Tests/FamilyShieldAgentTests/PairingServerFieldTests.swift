import XCTest
@testable import FamilyShieldAgent

/// #634 gate item G1: a store build pairs only with its own https server, shown locked; a build without one keeps
/// the editable field. Same rule as Android (#553) and the parent app (#579).
final class PairingServerFieldTests: XCTestCase {
    private let api = "https://api.osratech.com"

    func testABuildWithAServerLocksTheFieldToIt() throws {
        let builtIn = try XCTUnwrap(PairingServerField.builtIn(api))
        XCTAssertEqual(PairingServerField.field(builtIn: builtIn, previous: "http://192.168.1.5:3000"),
                       .init(value: api, locked: true))
        XCTAssertEqual(PairingServerField.serverToPair(builtIn: builtIn, typed: "https://other.example")?.absoluteString,
                       api, "whatever is in the field, the built-in server is the one paired with")
    }

    func testOnlyAnHttpsValueCountsAsABuiltInServer() {
        XCTAssertNil(PairingServerField.builtIn(nil))
        XCTAssertNil(PairingServerField.builtIn(""))
        XCTAssertNil(PairingServerField.builtIn("   "))
        XCTAssertNil(PairingServerField.builtIn("$(OSRA_API_BASE)"), "an unexpanded build setting is no server")
        XCTAssertNil(PairingServerField.builtIn("http://api.osratech.com"), "never a cleartext server")
        XCTAssertNil(PairingServerField.builtIn("api.osratech.com"), "no scheme is no server, not http by default")
        XCTAssertEqual(PairingServerField.builtIn("https://api.osratech.com/")?.absoluteString, api)
    }

    func testABuildWithoutOneKeepsTheEditableField() {
        XCTAssertEqual(PairingServerField.field(builtIn: nil, previous: "192.168.1.5:3000"),
                       .init(value: "192.168.1.5:3000", locked: false))
        XCTAssertEqual(PairingServerField.serverToPair(builtIn: nil, typed: "192.168.1.5:3000")?.absoluteString,
                       "http://192.168.1.5:3000", "local testing is unchanged")
    }

    func testTheTestBundleHasNoBuiltInServer() {
        // The package's test host sets no OSRA_API_BASE, so nothing in CI pairs against a hidden server.
        XCTAssertNil(PairingServerField.builtIn(bundle: .main))
    }

    func testThePairingScreenUsesTheRule() throws {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/FamilyShieldAgent/PairingView.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        XCTAssertTrue(text.contains(".disabled(builtInServer != nil)"), "the field is locked when the build has a server")
        XCTAssertTrue(text.contains("PairingServerField.serverToPair(builtIn: builtInServer, typed: serverInput)"),
                      "the claim goes to the built-in server")
        XCTAssertFalse(text.contains("PairingClient.normalizeServerURL(serverInput)"), "no path pairs with the typed text alone")
    }
}
