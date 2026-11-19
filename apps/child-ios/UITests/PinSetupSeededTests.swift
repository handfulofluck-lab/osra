import XCTest

/// #739: KP01's screens, reached through the Debug-only seed (Claude's decision 1, Ahmed's five conditions).
///
/// The argument strings are spelled here rather than imported on purpose: the constants live inside the app's
/// `#if DEBUG` code, and Ahmed's condition 2 keeps those strings out of a Release binary, so the test carries its
/// own copy instead of forcing them into shared code.
final class PinSetupSeededTests: XCTestCase {

    private let seedArgument = "-OSRAUITestSeed"
    private let pinSetup = "pin-setup"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func seededApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [seedArgument, pinSetup]
        return app
    }

    /// The seed lands on the parent-PIN setup screen rather than the pairing form: that is what a stored identity
    /// and no PIN means to the root view.
    func testTheSeedLandsOnTheParentPinSetupScreen() {
        let app = seededApp()
        app.launch()

        XCTAssertTrue(app.secureTextFields["pin.new"].waitForExistence(timeout: 30),
                      "the PIN setup screen never appeared")
        XCTAssertTrue(app.secureTextFields["pin.repeat"].exists)
        XCTAssertTrue(app.buttons["pin.save"].exists)
    }

    /// The setup screen's own rules, driven through the screen: an empty save is refused, a mismatched confirmation
    /// is refused, and the error is the Bureau's line rather than a crash or a silent pass.
    func testAnEmptyAndAMismatchedPinAreBothRefused() {
        let app = seededApp()
        app.launch()

        let new = app.secureTextFields["pin.new"]
        XCTAssertTrue(new.waitForExistence(timeout: 30))

        app.buttons["pin.save"].tap()
        XCTAssertTrue(app.staticTexts["pin.setError"].waitForExistence(timeout: 5),
                      "an empty PIN must be refused with a message")

        new.tap()
        new.typeText("1234")
        let repeatField = app.secureTextFields["pin.repeat"]
        repeatField.tap()
        repeatField.typeText("4321")
        app.buttons["pin.save"].tap()

        XCTAssertTrue(app.staticTexts["pin.setError"].exists, "a mismatched confirmation must be refused")
        XCTAssertTrue(app.secureTextFields["pin.new"].exists, "the screen stays put after a refusal")
    }

    /// Ahmed's condition 5: the seed never stands in for the parent PIN. With a PIN set, the repair action must
    /// still ask for it — the seed alone must not open a gated action.
    func testTheSeedDoesNotStandInForTheParentPin() {
        let app = seededApp()
        app.launch()

        let new = app.secureTextFields["pin.new"]
        XCTAssertTrue(new.waitForExistence(timeout: 30))
        new.tap()
        new.typeText("1234")
        let repeatField = app.secureTextFields["pin.repeat"]
        repeatField.tap()
        repeatField.typeText("1234")
        app.buttons["pin.save"].tap()

        let repair = app.buttons["status.repair"]
        XCTAssertTrue(repair.waitForExistence(timeout: 15), "the status screen did not follow the PIN save")
        repair.tap()

        XCTAssertTrue(app.secureTextFields["pin.gate"].waitForExistence(timeout: 10),
                      "a gated action opened without asking for the parent PIN")
    }
}
