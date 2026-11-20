import XCTest
import UIKit
import FamilyShieldAgent

/// #739, catalogue row **KP01**, the rows the seed made possible: a pasted PIN, a PIN longer than the app accepts,
/// the attempt count surviving a relaunch, a fast double tap on save, and the lock that follows five wrong PINs.
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

    /// The repair action sits at the bottom of the status screen; four swipes is what it took at the iPhone 13 size.
    /// Shared, so a change to how the gate is reached reaches every row that needs it.
    private func openGate(in app: XCUIApplication) {
        let repair = app.buttons["status.repair"]
        for _ in 0..<4 {
            if repair.exists { break }
            app.swipeUp()
        }
        XCTAssertTrue(repair.waitForExistence(timeout: 5), "the repair action is not on the status screen")
        repair.tap()
        XCTAssertTrue(app.secureTextFields["pin.gate"].waitForExistence(timeout: 10), "the gate did not appear")
    }

    private func submitWrongPin(into app: XCUIApplication) {
        type("9999", into: app.secureTextFields["pin.gate"])
        app.buttons["pin.continue"].tap()
    }

    /// XCUITest has no "any of these labels" wait, so poll. The callers use it to ask whether the gate said *some*
    /// shorter delay, which is the only assertion that works without parsing a numeral out of a sentence the
    /// catalogue is free to change.
    private func waitForMessage(in app: XCUIApplication, oneOf candidates: [String], timeout: TimeInterval) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            for candidate in candidates where app.staticTexts[candidate].exists {
                return candidate
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return nil
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

        openGate(in: app)
        submitWrongPin(into: app)
        XCTAssertTrue(app.staticTexts[L10n.tr("pin_wrong", 4)].waitForExistence(timeout: 5),
                      "the first wrong PIN must leave four tries")
        submitWrongPin(into: app)
        XCTAssertTrue(app.staticTexts[L10n.tr("pin_wrong", 3)].waitForExistence(timeout: 5),
                      "the second wrong PIN must leave three tries")

        app.terminate()
        let relaunched = XCUIApplication()
        relaunched.launch()
        XCTAssertTrue(relaunched.staticTexts["status.paired"].waitForExistence(timeout: 30),
                      "the unseeded relaunch did not come back to the paired status screen")

        openGate(in: relaunched)
        submitWrongPin(into: relaunched)

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

    /// Catalogue KP01, "the gate locks after five wrong PINs": the fifth failure must produce the app's own locked
    /// line, at the first delay. Before this row, nothing in the suite ever reached the lock, so
    /// `PinLockout.freeAttempts`, its doubling and `PinGateMessage`'s `.locked` arm were exercised by unit tests only
    /// and never on a screen.
    ///
    /// The mutants this catches are the bound and the branch: `freeAttempts` moved from 5 to 6, or the `locked`
    /// return in `ParentPinStore.check` deleted, leaves the fifth attempt saying `pin_wrong 1` and this row red.
    func testTheFifthWrongPinLocksTheGateRatherThanLeavingOneTry() {
        let app = launchSeeded()
        setUpPin(app)
        openGate(in: app)

        for left in stride(from: PinLockout.freeAttempts - 1, through: 1, by: -1) {
            submitWrongPin(into: app)
            XCTAssertTrue(app.staticTexts[L10n.tr("pin_wrong", left)].waitForExistence(timeout: 5),
                          "wrong PIN \(PinLockout.freeAttempts - left) of \(PinLockout.freeAttempts) must leave \(left) tries")
        }

        submitWrongPin(into: app)
        XCTAssertTrue(app.staticTexts[L10n.tr("pin_locked", Int(PinLockout.firstDelay))].waitForExistence(timeout: 5),
                      "the fifth wrong PIN must lock the gate with the app's first delay, not offer a sixth try")
        XCTAssertTrue(app.secureTextFields["pin.gate"].exists,
                      "a locked gate keeps its field: nothing is wiped and the parent can still reach it")
    }

    /// Catalogue KP01, "the locked line counts down": while locked the PIN is not compared, so a second tap inside
    /// the first delay must report the **remaining** time. The line therefore changes to one of the shorter delays
    /// the catalogue already has, instead of repeating the first delay as if nothing had passed.
    ///
    /// The mutants: `check` returning `firstDelay` instead of `remaining`, or the view keeping the first `message`,
    /// both leave the gate saying the same number twice and this row red. The row never parses a numeral out of the
    /// sentence — the Arabic `one` and `two` arms have no numeral — it asks whether the line is a *member* of the
    /// shorter delays instead.
    ///
    /// The second tap has to land inside the 30-second window (after it, a further failure would return 60), so the
    /// row waits 1.5 s to guarantee a tick and then taps once.
    func testTheLockedLineCountsDownOnASecondTap() {
        let app = launchSeeded()
        setUpPin(app)
        openGate(in: app)

        for _ in 0..<PinLockout.freeAttempts {
            submitWrongPin(into: app)
        }

        let message = app.staticTexts[A11yID.pinGateMessage]
        XCTAssertTrue(message.waitForExistence(timeout: 5), "the gate did not report its lock")
        XCTAssertEqual(message.label, L10n.tr("pin_locked", Int(PinLockout.firstDelay)),
                       "the lock must start at the app's first delay")
        let locked = message.label

        Thread.sleep(forTimeInterval: 1.5)
        app.buttons["pin.continue"].tap()

        let shorter = (1..<Int(PinLockout.firstDelay)).map { L10n.tr("pin_locked", $0) }
        let now = waitForMessage(in: app, oneOf: shorter, timeout: 10)
        XCTAssertNotNil(now,
                        "a second tap inside the lock must report the remaining time as one of the shorter delays; "
                        + "the gate still says \"\(locked)\"")
        XCTAssertNotEqual(now, Optional(locked), "the countdown did not move between the two taps")
    }
}
