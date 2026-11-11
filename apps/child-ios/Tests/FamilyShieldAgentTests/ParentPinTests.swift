import XCTest
@testable import FamilyShieldAgent

/// ADR-0036 (#372 PR A): the iPhone's parent PIN follows ADR-0010 as Android does. The validation and verify rows
/// come from `docs/test-vectors/parent-pin.tsv`, which Android's `ParentPinSharedCasesTest` reads too.
final class ParentPinTests: XCTestCase {

    private var secrets: InMemorySecretStore!
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    override func setUp() {
        super.setUp()
        secrets = InMemorySecretStore()
        AgentIdentityStore.secrets = secrets
        ParentPinStore.clear()
    }

    override func tearDown() {
        ParentPinStore.clear()
        super.tearDown()
    }

    private struct Row { let kind: String; let cells: [String] }

    private func sharedRows() throws -> [Row] {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while dir.path != "/" {
            let candidate = dir.appendingPathComponent("docs/test-vectors/parent-pin.tsv")
            if let text = try? String(contentsOf: candidate, encoding: .utf8) {
                return text.split(separator: "\n", omittingEmptySubsequences: true)
                    .filter { !$0.hasPrefix("#") }
                    .map { line in
                        let cells = line.split(separator: "\t", omittingEmptySubsequences: false)
                            .map { $0 == "<empty>" ? "" : String($0) }
                        return Row(kind: cells[0], cells: Array(cells.dropFirst()))
                    }
            }
            dir.deleteLastPathComponent()
        }
        // Not a skip: a table nobody reads would prove nothing.
        XCTFail("docs/test-vectors/parent-pin.tsv not reachable from \(#filePath)")
        return []
    }

    // MARK: - The shared table

    func testTheSharedTableHasBothKindsOfRow() throws {
        let rows = try sharedRows()
        XCTAssertGreaterThanOrEqual(rows.filter { $0.kind == "validate" }.count, 10)
        XCTAssertGreaterThanOrEqual(rows.filter { $0.kind == "verify" }.count, 8)
    }

    func testValidationMatchesEverySharedRow() throws {
        for row in try sharedRows() where row.kind == "validate" {
            let expected = row.cells[1] == "ok" ? nil : row.cells[1]
            XCTAssertEqual(ParentPin.validationError(row.cells[0]), expected, "validate '\(row.cells[0])'")
        }
    }

    func testVerificationMatchesEverySharedRow() throws {
        for row in try sharedRows() where row.kind == "verify" {
            let stored = row.cells[1].isEmpty ? nil : row.cells[1]
            XCTAssertEqual(ParentPin.verify(row.cells[0], stored: stored), row.cells[2] == "true",
                           "verify '\(row.cells[0])' against '\(row.cells[1])'")
        }
    }

    // MARK: - Hashing

    func testTheHashNeverHoldsThePinAndHasAndroidsFormat() throws {
        let stored = try XCTUnwrap(ParentPin.hash("4729"))
        XCTAssertTrue(stored.hasPrefix("pbkdf2$120000$"), stored)
        XCTAssertFalse(stored.contains("4729"))
        XCTAssertTrue(ParentPin.verify("4729", stored: stored))
        XCTAssertFalse(ParentPin.verify("4728", stored: stored))
    }

    func testTwoHashesOfOnePinDifferAndBothVerify() throws {
        let a = try XCTUnwrap(ParentPin.hash("583921"))
        let b = try XCTUnwrap(ParentPin.hash("583921"))
        XCTAssertNotEqual(a, b, "a fresh salt each time")
        XCTAssertTrue(ParentPin.verify("583921", stored: a))
        XCTAssertTrue(ParentPin.verify("583921", stored: b))
    }

    func testTheCompareLooksAtEveryByte() {
        XCTAssertTrue(ParentPin.constantTimeEquals([1, 2, 3], [1, 2, 3]))
        XCTAssertFalse(ParentPin.constantTimeEquals([1, 2, 3], [1, 2, 4]))
        XCTAssertFalse(ParentPin.constantTimeEquals([1, 2, 3], [1, 2]))
    }

    // MARK: - Lockout

    func testFiveWrongPinsLockForThirtySecondsThenTheDelayDoubles() {
        var lockout = PinLockout()
        for _ in 0..<4 { lockout.recordFailure(now: t0) }
        XCTAssertFalse(lockout.isLocked(now: t0), "four tries are free")
        lockout.recordFailure(now: t0)
        XCTAssertEqual(lockout.remaining(now: t0), 30, accuracy: 0.001)
        XCTAssertFalse(lockout.isLocked(now: t0.addingTimeInterval(30)))
        lockout.recordFailure(now: t0.addingTimeInterval(30))
        XCTAssertEqual(lockout.remaining(now: t0.addingTimeInterval(30)), 60, accuracy: 0.001)
        lockout.recordFailure(now: t0.addingTimeInterval(90))
        XCTAssertEqual(lockout.remaining(now: t0.addingTimeInterval(90)), 120, accuracy: 0.001)
    }

    func testTheDelayStopsGrowingAtAnHour() {
        var lockout = PinLockout()
        for _ in 0..<30 { lockout.recordFailure(now: t0) }
        XCTAssertEqual(lockout.remaining(now: t0), PinLockout.maxDelay, accuracy: 0.001)
    }

    func testACorrectPinResetsTheCount() {
        var lockout = PinLockout()
        for _ in 0..<4 { lockout.recordFailure(now: t0) }
        lockout.recordSuccess()
        lockout.recordFailure(now: t0)
        XCTAssertFalse(lockout.isLocked(now: t0))
        XCTAssertEqual(lockout.failures, 1)
    }

    // MARK: - The store

    func testTheStoreRefusesAWeakPinAndKeepsOnlyTheHash() {
        XCTAssertFalse(ParentPinStore.set("1234"))
        XCTAssertFalse(ParentPinStore.isConfigured)
        XCTAssertTrue(ParentPinStore.set("4729"))
        XCTAssertTrue(ParentPinStore.isConfigured)
        let stored = secrets.read(ParentPinStore.account) ?? ""
        XCTAssertTrue(stored.hasPrefix("pbkdf2$"))
        XCTAssertFalse(stored.contains("4729"))
    }

    func testFiveWrongPinsLockTheGateAndEvenTheRightPinWaits() {
        XCTAssertTrue(ParentPinStore.set("4729"))
        XCTAssertEqual(ParentPinStore.check("1111", now: t0), .wrong(attemptsLeft: 4))
        for left in [3, 2, 1] { XCTAssertEqual(ParentPinStore.check("1111", now: t0), .wrong(attemptsLeft: left)) }
        XCTAssertEqual(ParentPinStore.check("1111", now: t0), .locked(seconds: 30))
        XCTAssertEqual(ParentPinStore.check("4729", now: t0.addingTimeInterval(10)), .locked(seconds: 20),
                       "while locked the PIN is not compared")
        XCTAssertEqual(ParentPinStore.check("4729", now: t0.addingTimeInterval(31)), .ok)
        XCTAssertTrue(ParentPinStore.isConfigured, "a lockout never wipes anything")
        XCTAssertEqual(ParentPinStore.check("1111", now: t0.addingTimeInterval(32)), .wrong(attemptsLeft: 4),
                       "the right PIN reset the count")
    }

    func testTheGateMessages() {
        XCTAssertNil(PinGateMessage.text(for: .ok))
        XCTAssertEqual(PinGateMessage.text(for: .wrong(attemptsLeft: 1)), "Wrong PIN. 1 try left before a pause.")
        XCTAssertEqual(PinGateMessage.text(for: .locked(seconds: 30)), "Too many wrong PINs. Try again in 30 s.")
    }
}
