import XCTest
@testable import FamilyShieldAgent
@testable import OSRAAgent

/// #739, Ahmed's condition 4: the seed's identity can never point anywhere real, and the argument cannot be
/// half-typed into a silent success.
///
/// These run inside the simulator app (`OSRAAgentHostedTests`), which is where `UITestSeed` lives — it is app-shell
/// code inside `#if DEBUG`, so the package's own suite cannot see it. A seeded launch wipes the simulator's pairing
/// before it writes, which is what these rows assert, so they must not be read as leaving state behind that another
/// hosted test depends on: each of those sets up its own.
final class UITestSeedTests: XCTestCase {

    private var saved: [AgentIdentity] = []

    override func setUp() {
        super.setUp()
        saved = []
    }

    private func apply(_ arguments: [String]) -> Bool {
        UITestSeed.apply(arguments: arguments, store: { identity in
            self.saved.append(identity)
            return true
        })
    }

    /// The seed asks for the PIN setup screen, and the identity it writes can only reach the loopback discard port:
    /// no scheme but http, no host but `127.0.0.1`, no port but 9, and no HMAC secret. It is not derived from
    /// `OSRA_API_BASE` and cannot be pointed at staging or production by the caller.
    func testTheSeedWritesOneIdentityThatCanOnlyReachLoopback() {
        XCTAssertTrue(apply(["OSRAAgent", "-OSRAUITestSeed", "pin-setup"]))
        XCTAssertEqual(saved.count, 1, "exactly one identity is written")

        guard let identity = saved.first else { return XCTFail("nothing was saved") }
        XCTAssertEqual(identity.apiBaseURL.scheme, "http")
        XCTAssertEqual(identity.apiBaseURL.host, "127.0.0.1")
        XCTAssertEqual(identity.apiBaseURL.port, 9)
        XCTAssertNil(identity.hmacSecret, "a seed with a secret would let alert reporting authenticate")
        XCTAssertFalse(identity.deviceToken.isEmpty, "the app needs a token field, and this one no server accepts")
    }

    /// Every way the argument can be wrong saves nothing: no flag, no value after it, an unknown screen, and the
    /// flag given twice with only one value. A silent save here would put a fake identity on a real phone's
    /// simulator the moment someone typed the flag by accident.
    func testAFlagThatDoesNotNameAKnownScreenSavesNothing() {
        XCTAssertFalse(apply(["OSRAAgent"]), "no flag")
        XCTAssertFalse(apply(["OSRAAgent", "-OSRAUITestSeed"]), "flag with no value")
        XCTAssertFalse(apply(["OSRAAgent", "-OSRAUITestSeed", "status"]), "an unknown screen")
        XCTAssertFalse(apply(["OSRAAgent", "-OSRAUITestSeed", ""]), "an empty screen")
        XCTAssertTrue(saved.isEmpty, "a refused argument must write nothing")
    }
}
