import XCTest
@testable import FamilyShieldAgent

/// #760 follow-up, Codex `7158872749`: `@MainActor` was glued to the end of a doc-comment line, so it was part of the
/// comment and the class was never isolated — the published status could be written from the authorizer's async
/// completion off the main actor. A comment cannot hold an attribute, so the test reads the line that carries it.
final class AlarmPermissionIsolationTests: XCTestCase {

    private func source() throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/FamilyShieldAgent/AlarmRingingPermission.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testTheAttributeIsNotInsideACommentLine() throws {
        let text = try source()
        XCTAssertFalse(text.contains(".@MainActor"),
                       "an attribute at the end of a doc sentence is part of the comment, not the code")
        for line in text.split(separator: "\n") where line.contains("@MainActor") {
            XCTAssertFalse(line.trimmingCharacters(in: .whitespaces).hasPrefix("///"),
                           "the attribute has its own line: \(line)")
        }
    }

    func testTheClassIsIsolated() throws {
        let lines = try source().split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let classLine = try XCTUnwrap(lines.firstIndex(of: "public final class AlarmRingingPermission: ObservableObject {"),
                                      "the class declaration moved; update this test with it")
        XCTAssertEqual(lines[classLine - 1], "@MainActor",
                       "`@MainActor` is the line directly above the class it isolates")
    }
}
