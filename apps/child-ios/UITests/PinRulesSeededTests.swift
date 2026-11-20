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

    /// Taps, waits for the field to actually take focus, then types.
    ///
    /// The bare `tap(); typeText()` failed once with *"Neither element nor any descendant has keyboard focus"* — a
    /// tap landing while a sheet was still settling. That is the harness being impatient, not the app misbehaving,
    /// so the wait belongs here rather than in a retry of the whole case.
    private func type(_ text: String, into field: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(field.waitForExistence(timeout: 10), "the field never appeared")
        let deadline = Date().addingTimeInterval(5)
        while !field.isHittable && Date() < deadline { usleep(100_000) }
        field.tap()
        _ = app.keyboards.element.waitForExistence(timeout: 3)   // the keyboard attaching is the focus signal
        field.typeText(text)
    }

    private func save(_ app: XCUIApplication) {
        app.buttons["pin.save"].tap()
    }

    /// Save on the seeded screen, so the later rows start from a status screen with a PIN set.
    private func setUpPin(_ app: XCUIApplication) {
        type(goodPin, into: app.secureTextFields["pin.new"], in: app)
        type(goodPin, into: app.secureTextFields["pin.repeat"], in: app)
        save(app)
        XCTAssertTrue(app.staticTexts["status.paired"].waitForExistence(timeout: 20),
                      "the status screen did not follow a valid PIN")
    }

    /// Catalogue E12, the long case: nine digits never reach the hash. The refusal is the app's own line, and the
    /// screen stays where it is so the parent can correct it.
    func testAPinLongerThanEightDigitsIsRefused() {
        let app = launchSeeded()
        type("123456789", into: app.secureTextFields["pin.new"], in: app)
        type("123456789", into: app.secureTextFields["pin.repeat"], in: app)
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

        type("123456789012", into: app.secureTextFields["pin.repeat"], in: app)
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
            type("9999", into: app.secureTextFields["pin.gate"], in: app)
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

    /// Catalogue KP01, "backgrounding the app mid-entry": a child who leaves the app with a half-typed PIN and comes
    /// back must find the gate still asking, and must not get the attempts they already spent back.
    ///
    /// **The first version of this row asserted nothing**, and Antigravity and Ahmed both caught it: it typed two
    /// digits, backgrounded, and then checked "four tries left" — but a typed digit spends nothing, because
    /// `ParentPinStore.check` runs only when Continue is tapped. Four was what a fresh counter also reports, so a
    /// non-persistent lockout passed it. This version **spends an attempt before backgrounding** and requires three
    /// left afterwards, which only holds if the count survived.
    func testBackgroundingMidEntryNeitherBypassesNorResetsTheGate() {
        let app = launchSeeded()
        setUpPin(app)

        func openGate() {
            let repair = app.buttons["status.repair"]
            for _ in 0..<4 {
                if repair.exists { break }
                app.swipeUp()
            }
            XCTAssertTrue(repair.waitForExistence(timeout: 5), "the gated action is not on the status screen")
            repair.tap()
            XCTAssertTrue(app.secureTextFields["pin.gate"].waitForExistence(timeout: 10),
                          "the gate did not appear")
        }

        func wrongPin(_ pin: String) {
            type(pin, into: app.secureTextFields["pin.gate"], in: app)
            app.buttons["pin.continue"].tap()
        }

        openGate()
        wrongPin("0000")
        XCTAssertTrue(app.staticTexts[L10n.tr("pin_wrong", 4)].waitForExistence(timeout: 5),
                      "the first wrong attempt must leave four tries")

        // Mid-entry means a *half-typed* field, not an empty one: two digits go in and Continue is never tapped,
        // so the app is left exactly as a child would leave it when they press home. Ahmed asked for this and he
        // was right — the previous version spent an attempt and then left no partial entry behind.
        type("99", into: app.secureTextFields["pin.gate"], in: app)

        XCUIDevice.shared.press(.home)
        app.activate()

        // "No crash, no pass" is the requirement, not "the sheet survives": iOS may dismiss a presented sheet when
        // the app goes to the background, and the status screen behind it is not gated — the action is.
        if !app.secureTextFields["pin.gate"].exists {
            XCTAssertTrue(app.staticTexts["status.paired"].waitForExistence(timeout: 15),
                          "the app did not come back from the background")
            openGate()
        }

        wrongPin("0000")
        XCTAssertTrue(app.staticTexts[L10n.tr("pin_wrong", 3)].waitForExistence(timeout: 5),
                      "the attempt spent before backgrounding must still be spent: three tries, not four")
    }

    /// Catalogue E13, fast taps: two taps on save with no wait between them must not crash and must not leave the
    /// parent on a half-saved screen.
    ///
    /// **What this row does not prove:** that the PIN was written once. A UI test cannot see the number of Keychain
    /// writes, so a duplicate write with the same value would pass here. The catalogue asks for "no crash, no pass",
    /// and that is what it asserts.
    func testAFastDoubleTapOnSaveDoesNotCrashOrStall() {
        let app = launchSeeded()
        type(goodPin, into: app.secureTextFields["pin.new"], in: app)
        type(goodPin, into: app.secureTextFields["pin.repeat"], in: app)

        // An **absolute** point, resolved before the first tap, not a coordinate bound to the element: a
        // `coordinate(withNormalizedOffset:)` derived from the button re-resolves the element on every tap, so the
        // second tap failed with "No matches found" once the screen had moved on — which is the app behaving
        // correctly and the row measuring the wrong thing. Two taps at the same screen point is what a person's
        // fast double tap is.
        let frame = app.buttons["pin.save"].frame
        let point = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
            .withOffset(CGVector(dx: frame.midX, dy: frame.midY))
        point.tap()
        point.tap()

        XCTAssertTrue(app.staticTexts["status.paired"].waitForExistence(timeout: 20),
                      "a double tap on save must still land on the status screen")
        XCTAssertFalse(app.staticTexts["pin.setError"].exists, "a double tap must not produce a refusal")
    }
}
