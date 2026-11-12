import XCTest
@testable import FamilyShieldAgent

/// #669: every control on the OSRA Kids screens carries a stable accessibility identifier, so the test bed's
/// XCUITest driver runs the same script in English and in Arabic.
final class A11yIDTests: XCTestCase {

    private static let views = ["PairingView.swift", "ParentPinViews.swift", "AppGroupsView.swift"]
    private static let controls = ["Button(", "TextField(", "SecureField(", "NavigationLink(", "Toggle("]

    func testTheIdentifiersAreUniqueStableAscii() {
        XCTAssertEqual(Set(A11yID.all).count, A11yID.all.count, "no two controls share an identifier")
        for id in A11yID.all {
            XCTAssertFalse(id.isEmpty)
            XCTAssertTrue(id.unicodeScalars.allSatisfy { $0.isASCII && !CharacterSet.whitespaces.contains($0) }, id)
        }
        XCTAssertEqual(A11yID.group("g1", .blocked), "groups.g1.blocked")
        XCTAssertEqual(Set(A11yID.GroupPart.allCases.map { A11yID.group("g1", $0) }).count, A11yID.GroupPart.allCases.count)
    }

    /// Each control is followed by its `.accessibilityIdentifier(` before the next control starts. A control added
    /// without one fails here, in the file and line it was added.
    func testEveryControlHasAnIdentifier() throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/FamilyShieldAgent")
        var controlsSeen = 0
        for file in Self.views {
            let lines = try String(contentsOf: folder.appendingPathComponent(file), encoding: .utf8)
                .components(separatedBy: "\n")
            var pending: (line: Int, text: String)?
            for (index, raw) in lines.enumerated() {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("//") || line.hasPrefix("///") { continue }
                if Self.controls.contains(where: { line.hasPrefix($0) }) {
                    if let open = pending { XCTFail("\(file):\(open.line): no accessibilityIdentifier for \(open.text)") }
                    pending = (index + 1, line)
                    controlsSeen += 1
                }
                if line.contains(".accessibilityIdentifier(A11yID.") { pending = nil }
            }
            if let open = pending { XCTFail("\(file):\(open.line): no accessibilityIdentifier for \(open.text)") }
        }
        XCTAssertGreaterThanOrEqual(controlsSeen, 19, "the scan found the screens' controls")
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
                     "pinNew", "pinRepeat", "pinSetError", "pinSave", "pinGate", "pinGateMessage", "pinContinue",
                     "groupsNewName", "groupsNewChoose", "groupsNewChosen", "groupsNewAdd", "groupsError"]
        XCTAssertEqual(names.count, A11yID.all.count, "every identifier in A11yID.all is listed here")
        for name in names {
            XCTAssertTrue(sources.contains(".accessibilityIdentifier(A11yID.\(name))"), name)
        }
    }
}
