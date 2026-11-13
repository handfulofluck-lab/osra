import XCTest
@testable import FamilyShieldAgent

/// #669: every control on the OSRA Kids screens carries a stable accessibility identifier, so the test bed's
/// XCUITest driver runs the same script in English and in Arabic.
final class A11yIDTests: XCTestCase {

    private static let views = ["PairingView.swift", "ParentPinViews.swift", "AppGroupsView.swift"]
    /// A control starts a line as `Button(`, `Button {`, `Menu(` and so on. Both call shapes count, so a control
    /// written with a `label:` closure is seen too.
    private static let controlPattern = try! NSRegularExpression(
        pattern: #"^(Button|TextField|SecureField|NavigationLink|Toggle|Menu|Picker)\s*[({]"#)

    func testTheIdentifiersAreUniqueStableAscii() {
        XCTAssertEqual(Set(A11yID.all).count, A11yID.all.count, "no two controls share an identifier")
        for id in A11yID.all {
            XCTAssertFalse(id.isEmpty)
            XCTAssertTrue(id.unicodeScalars.allSatisfy { $0.isASCII && !CharacterSet.whitespaces.contains($0) }, id)
        }
        XCTAssertEqual(A11yID.group("g1", .blocked), "groups.g1.blocked")
        XCTAssertEqual(Set(A11yID.GroupPart.allCases.map { A11yID.group("g1", $0) }).count, A11yID.GroupPart.allCases.count)
    }

    /// The controls in `source` with no `.accessibilityIdentifier(` before the next control starts, as
    /// `line: text`. A control added without one is reported at the line it was added.
    static func missingIdentifiers(in source: String) -> (controls: Int, missing: [String]) {
        var controls = 0
        var missing: [String] = []
        var pending: String?
        for (index, raw) in source.components(separatedBy: "\n").enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("//") { continue }
            let range = NSRange(line.startIndex..., in: line)
            if controlPattern.firstMatch(in: line, range: range) != nil {
                if let open = pending { missing.append(open) }
                pending = "\(index + 1): \(line)"
                controls += 1
            }
            if line.contains(".accessibilityIdentifier(A11yID.") { pending = nil }
        }
        if let open = pending { missing.append(open) }
        return (controls, missing)
    }

    func testEveryControlHasAnIdentifier() throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/FamilyShieldAgent")
        var controlsSeen = 0
        for file in Self.views {
            let source = try String(contentsOf: folder.appendingPathComponent(file), encoding: .utf8)
            let result = Self.missingIdentifiers(in: source)
            controlsSeen += result.controls
            for open in result.missing { XCTFail("\(file):\(open): no accessibilityIdentifier") }
        }
        XCTAssertGreaterThanOrEqual(controlsSeen, 20, "the scan found the screens' controls")
    }

    /// The scan itself: each control shape without an identifier is caught, and one with an identifier is not.
    func testTheScanSeesEveryControlShape() {
        let unmarked = [
            "Button { save() } label: {\n    Text(\"Save\")\n}",
            "Button(\"Save\") { save() }",
            "Menu(\"More\") { Text(\"A\") }",
            "Menu {\n    Text(\"A\")\n} label: {\n    Text(\"More\")\n}",
            "Picker(\"Kind\", selection: $kind) { Text(\"A\") }",
            "Toggle(\"On\", isOn: $on)",
            "NavigationLink(\"Next\") { Text(\"B\") }",
            "SecureField(\"PIN\", text: $pin)",
            "TextField(\"Name\", text: $name)",
        ]
        for fixture in unmarked {
            XCTAssertEqual(Self.missingIdentifiers(in: fixture).missing.count, 1, fixture)
        }
        let marked = "Button { save() } label: {\n    Text(\"Save\")\n}\n.accessibilityIdentifier(A11yID.pinSave)"
        XCTAssertEqual(Self.missingIdentifiers(in: marked).missing, [])
        let twoInARow = "Button(\"A\") { }\nButton(\"B\") { }\n.accessibilityIdentifier(A11yID.pinSave)"
        XCTAssertEqual(Self.missingIdentifiers(in: twoInARow).missing.count, 1, "the first of two controls is caught")
    }

    func testEveryFixedIdentifierIsUsedOnAScreen() throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/FamilyShieldAgent")
        let sources = try Self.views.map { try String(contentsOf: folder.appendingPathComponent($0), encoding: .utf8) }
            .joined()
        let names = ["pairServer", "pairCode", "pairName", "pairError", "pairButton",
                     "statusPaired", "statusChildName", "statusServer", "statusLastSynced", "statusSyncNow",
                     "statusSyncFailed", "statusScreenTime", "statusScreenTimeButton", "statusLocation",
                     "statusLocationButton", "statusGroups", "statusRepair",
                     "pinSetReason", "pinNew", "pinRepeat", "pinSetError", "pinSave", "pinGate", "pinGateMessage", "pinContinue",
                     "groupsNewName", "groupsNewChoose", "groupsNewChosen", "groupsNewAdd", "groupsError"]
        XCTAssertEqual(names.count, A11yID.all.count, "every identifier in A11yID.all is listed here")
        for name in names {
            XCTAssertTrue(sources.contains(".accessibilityIdentifier(A11yID.\(name))"), name)
        }
    }

    /// U11 (#696): the parent-PIN screen cannot be skipped, so its first line says why, in both languages.
    func testThePinScreenSaysWhyFirst() throws {
        XCTAssertEqual(L10n.tr("pin_set_reason", language: "en"),
                       "Set a parent PIN so only a parent can change OSRA Kids or pair this phone again.")
        XCTAssertNotEqual(L10n.tr("pin_set_reason", language: "ar"), "pin_set_reason", "the Bureau's Arabic is present")
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/FamilyShieldAgent/ParentPinViews.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        let reason = try XCTUnwrap(text.range(of: "Text(L10n.tr(\"pin_set_reason\"))"))
        let field = try XCTUnwrap(text.range(of: "L10n.tr(\"pin_new_field\")"))
        XCTAssertLessThan(reason.lowerBound, field.lowerBound, "the reason comes before the PIN fields")
    }
}
