import XCTest
import FamilyShieldAgent

/// #739: the UI-test target and its smoke case. This is the skeleton Claude approved: it proves the harness
/// launches the real app on the CI simulator and reaches a screen by accessibility identifier, before any
/// catalogue row depends on it.
///
/// Row KP01 is the only escape row that can run here — the shield rows (KS03, KX01, KO01) need a device in
/// Family Controls `.child` authorisation. Its unit half already runs (`ParentPinTests`); the xcui half needs a
/// seeded identity, which is the `#if DEBUG` launch argument Claude and Ahmed are reviewing.
final class AgentLaunchTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// The app starts on the pairing form when nothing is paired: the code field and the pair button are there,
    /// and typing is limited to six digits before the button can be enabled.
    ///
    /// A stale identity in the simulator's Keychain turns this red on purpose: this row's job is to say what
    /// state the app actually launched in, not to accept either screen.
    func testTheAppLaunchesToThePairingScreen() throws {
        let app = XCUIApplication()
        app.launch()

        let code = app.textFields[A11yID.pairCode]
        XCTAssertTrue(code.waitForExistence(timeout: 30), "the pairing code field never appeared")

        let pair = app.buttons[A11yID.pairButton]
        XCTAssertTrue(pair.exists, "the pair button is missing on the pairing screen")
        XCTAssertFalse(pair.isEnabled, "the pair button must stay disabled until six digits are typed")

        code.tap()
        code.typeText("123456")

        XCTAssertTrue(pair.isEnabled, "six digits must enable the pair button")
        XCTAssertEqual(code.value as? String, "123456", "the field holds what was typed")
    }
}
