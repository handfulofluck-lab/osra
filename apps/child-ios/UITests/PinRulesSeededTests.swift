import XCTest
import UIKit
import FamilyShieldAgent

/// #739, catalogue row **KP01**, the rows the seed made possible: a pasted PIN, a PIN longer than the app accepts,
/// the attempt count surviving a relaunch, and a fast double tap on save.
///
/// Every assertion is against a line the app itself renders (`ParentPin.validationError`'s refusals and
/// `PinGateMessage`) rather than a sentence written here, so a wording change in the catalogue moves the test with
/// the app instead of reddening it.
final class PinRulesSeededTests: XCTestCase {

    private let seedArgument = "-OSRAUITestSeed"
    private let pinSetup = "pin-setup"
    /// A PIN the app accepts: four digits, not one repeated digit, and not on `ParentPin.weakPins` ("1234" is).
    private let goodPin = "2085"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launchSeeded() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [seedArgument, pinSetup]
        app.launch()
        XCTAssertTrue(app.secureTextFields["pin.new"].waitForExistence(timeout: 30),
                      "the seeded launch did not reach the PIN setup screen")
        return app
    }

    private func type(_ text: String, into field: XCUIElement) {
        field.tap()
        field.typeText(text)
    }

    private func save(_ app: XCUIApplication) {
        app.buttons["pin.save"].tap()
    }

    /// Save on the seeded screen, so the later rows start from a status screen with a PIN set.
    private func setUpPin(_ app: XCUIApplication) {
        type(goodPin, into: app.secureTextFields["pin.new"])
        type(goodPin, into: app.secureTextFields["pin.repeat"])
        save(app)
        XCTAssertTrue(app.staticTexts["status.paired"].waitForExistence(timeout: 20),
                      "the status screen did not follow a valid PIN")
    }

    /// Catalogue E12, the long case: nine digits never reach the hash. The refusal is the app's own line, and the
    /// screen stays where it is so the parent can correct it.
    func testAPinLongerThanEightDigitsIsRefused() {
        let app = launchSeeded()
        type("123456789", into: app.secureTextFields["pin.new"])
        type("123456789", into: app.secureTextFields["pin.repeat"])
        save(app)

        XCTAssertTrue(app.staticTexts[L10n.tr("pin_too_long")].waitForExistence(timeout: 5),
                      "nine digits must be refused with the app's own too-long line")
        XCTAssertTrue(app.secureTextFields["pin.new"].exists, "the setup screen stays put after a refusal")
    }

    /// Catalogue E12, the pasted case: a value arriving in one block must be judged by the same rules as a typed
    /// one. The PIN field uses a number pad, so a *typed* letter is impossible and the first version of this row was
    /// testing nothing — the character never arrived. A real paste can carry anything, so that is what this does:
    /// twelve digits through the pasteboard must be refused as too long rather than silently truncated to eight.
    func testAPastedValueIsJudgedByTheSameRulesRatherThanTruncated() {
        let app = launchSeeded()
        UIPasteboard.general.string = "123456789012"

        let field = app.secureTextFields["pin.new"]
        field.press(forDuration: 1.2)
        let paste = app.menuItems["Paste"]
        guard paste.waitForExistence(timeout: 5) else {
            return XCTFail("the paste menu did not appear; this row cannot judge pasting until it does")
        }
        paste.tap()

        type("123456789012", into: app.secureTextFields["pin.repeat"])
        save(app)

        XCTAssertTrue(app.staticTexts[L10n.tr("pin_too_long")].waitForExistence(timeout: 5),
                      "a pasted twelve-digit value must be refused as too long, not truncated to eight")
    }

    /// Catalogue KP01, "attempt limit survives a relaunch": the count lives in the app-group defaults, so a killed
    /// app must not hand a child a fresh set of five. Two wrong attempts, a relaunch, then one more must leave
    /// **two** — which is only true if the count came back with the app.
    ///
    /// The relaunch deliberately carries **no seed**: the seed wipes the identity and PIN, which would reset the
    /// very thing this row measures.
    func testTheAttemptCountSurvivesARelaunch() {
        let app = launchSeeded()
        setUpPin(app)

        func openGate() {
            let repair = app.buttons["status.repair"]
            for _ in 0..<4 {
                if repair.exists { break }
                app.swipeUp()
            }
            XCTAssertTrue(repair.waitForExistence(timeout: 5), "the repair action is not on the status screen")
            repair.tap()
            XCTAssertTrue(app.secureTextFields["pin.gate"].waitForExistence(timeout: 10),
                          "the gate did not appear")
        }

        func wrongPin() {
            type("9999", into: app.secureTextFields["pin.gate"])
            app.buttons["pin.continue"].tap()
        }

        openGate()
        wrongPin()
        XCTAssertTrue(app.staticTexts[L10n.tr("pin_wrong", 4)].waitForExistence(timeout: 5),
                      "the first wrong PIN must leave four tries")
        wrongPin()
        XCTAssertTrue(app.staticTexts[L10n.tr("pin_wrong", 3)].waitForExistence(timeout: 5),
                      "the second wrong PIN must leave three tries")

        app.terminate()
        let relaunched = XCUIApplication()
        relaunched.launch()
        XCTAssertTrue(relaunched.staticTexts["status.paired"].waitForExistence(timeout: 30),
                      "the unseeded relaunch did not come back to the paired status screen")

        let repair = relaunched.buttons["status.repair"]
        for _ in 0..<4 {
            if repair.exists { break }
            relaunched.swipeUp()
        }
        repair.tap()
        XCTAssertTrue(relaunched.secureTextFields["pin.gate"].waitForExistence(timeout: 10))
        type("9999", into: relaunched.secureTextFields["pin.gate"])
        relaunched.buttons["pin.continue"].tap()

        XCTAssertTrue(relaunched.staticTexts[L10n.tr("pin_wrong", 2)].waitForExistence(timeout: 5),
                      "the third wrong attempt must leave two tries: the count did not survive the relaunch")
    }

    /// Catalogue E13, fast taps: two taps on save with no wait between them must not crash and must not leave the
    /// parent on a half-saved screen.
    ///
    /// **What this row does not prove:** that the PIN was written once. A UI test cannot see the number of Keychain
    /// writes, so a duplicate write with the same value would pass here. The catalogue asks for "no crash, no pass",
    /// and that is what it asserts.
    func testAFastDoubleTapOnSaveDoesNotCrashOrStall() {
        let app = launchSeeded()
        type(goodPin, into: app.secureTextFields["pin.new"])
        type(goodPin, into: app.secureTextFields["pin.repeat"])

        // A coordinate tap, not an element tap: after the first tap the button no longer exists, so a second
        // element tap failed with "No matches found" — which was the app behaving correctly and the row measuring
        // the wrong thing. The same screen point twice is what a fast double tap by a person actually is.
        let point = app.buttons["pin.save"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        point.tap()
        point.tap()

        XCTAssertTrue(app.staticTexts["status.paired"].waitForExistence(timeout: 20),
                      "a double tap on save must still land on the status screen")
        XCTAssertFalse(app.staticTexts["pin.setError"].exists, "a double tap must not produce a refusal")
    }
}
