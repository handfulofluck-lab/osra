import Foundation
import XCTest
@testable import FamilyShieldAgent

@MainActor
final class AlarmKitRingBackendTests: XCTestCase {
    private let commandID = UUID(uuidString: "6F1C2B8E-3D4A-4E5F-9A0B-1C2D3E4F5A6B")!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "test.ring.alarmkit.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removeObject(forKey: AlarmKitRingBackend.activeCommandIDsKey)
    }

    override func tearDown() {
        defaults.removeObject(forKey: AlarmKitRingBackend.activeCommandIDsKey)
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func backend(leadTime: TimeInterval = 5, chainInterval: TimeInterval = 6,
                         now: @escaping () -> Date = Date.init) -> AlarmKitRingBackend {
        AlarmKitRingBackend(leadTime: leadTime, chainInterval: chainInterval, now: now, defaults: defaults)
    }

    func testSentinelIDPreservesCommandPrefixAndIsDeterministic() {
        let backend = backend()
        let sentinel = backend.sentinelID(for: commandID, index: 1)
        let again = backend.sentinelID(for: commandID, index: 1)
        XCTAssertEqual(sentinel, again)
        XCTAssertEqual(sentinel.uuidString.prefix(24), commandID.uuidString.prefix(24))
        XCTAssertEqual(sentinel.uuidString.suffix(12), "000000000001")
        XCTAssertNotEqual(sentinel, commandID)
    }

    func testSentinelIDsAreUniqueAcrossIndexes() {
        let backend = backend()
        let ids = Set((1...50).map { backend.sentinelID(for: commandID, index: $0) })
        XCTAssertEqual(ids.count, 50, "each sentinel index must produce a distinct UUID")
    }

    func testSentinelCountMatchesDuration() {
        let backend = backend()
        XCTAssertEqual(backend.sentinelCount(), 49)
    }

    func testChainDatesStartAtLeadTimeAndCoverDuration() {
        let backend = backend()
        let dates = backend.chainDates()
        XCTAssertEqual(dates.first, 5)
        XCTAssertEqual(dates.last, 299)
        XCTAssertEqual(dates.count, 50)
        for index in 1..<dates.count {
            XCTAssertEqual(dates[index] - dates[index - 1], 6, accuracy: 0.001)
        }
    }

    func testSentinelIDsForCommandMatchChainDates() {
        let backend = backend()
        let sentinels = backend.sentinelIDs(for: commandID)
        XCTAssertEqual(sentinels.count, backend.chainDates().count - 1)
        XCTAssertEqual(sentinels.first, backend.sentinelID(for: commandID, index: 1))
        XCTAssertEqual(sentinels.last, backend.sentinelID(for: commandID, index: 49))
    }

    func testDifferentCommandsProduceDifferentSentinelSets() {
        let other = UUID(uuidString: "A1B2C3D4-E5F6-7890-1234-567890ABCDEF")!
        let backend = backend()
        let first = Set(backend.sentinelIDs(for: commandID))
        let second = Set(backend.sentinelIDs(for: other))
        XCTAssertTrue(first.isDisjoint(with: second), "sentinel sets for different commands must not overlap")
    }

    func testInitRestoresPersistedActiveCommandIDs() {
        defaults.set([commandID.uuidString], forKey: AlarmKitRingBackend.activeCommandIDsKey)
        let restored = backend()
        XCTAssertTrue(restored.activeCommandIDs.contains(commandID))
    }

    func testSentinelIDsAreEmptyWhenRemainingTimeIsShort() {
        let fixed = Date(timeIntervalSince1970: 1_000)
        let backend = backend(now: { fixed })
        XCTAssertEqual(backend.sentinelCount(until: fixed.addingTimeInterval(10)), 0)
        XCTAssertTrue(backend.sentinelIDs(for: commandID, until: fixed.addingTimeInterval(10)).isEmpty)
    }

    func testChainDatesAreCappedAtRemainingTime() {
        let fixed = Date(timeIntervalSince1970: 1_000)
        let backend = backend(now: { fixed })
        let dates = backend.chainDates(until: fixed.addingTimeInterval(100))
        XCTAssertEqual(dates.first, 5)
        XCTAssertLessThanOrEqual(dates.last!, 100)
        XCTAssertEqual(dates.count, backend.sentinelCount(until: fixed.addingTimeInterval(100)) + 1)
        for offset in dates {
            XCTAssertLessThanOrEqual(offset, 100)
        }
    }
}
