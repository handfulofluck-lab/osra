import Foundation
import XCTest
@testable import FamilyShieldAgent

final class InMemoryRingStore: RingStore {
    var stored: RingState?
    func load() -> RingState? { stored }
    func save(_ state: RingState?) { stored = state }
}

final class FakeRingBackend: RingBackend {
    let available: Bool
    var authorized: Bool
    var scheduled: [UUID] = []
    var stopCalls: [UUID] = []
    var authorizationCalls = 0
    var scheduleError: Error?
    private var continuation: AsyncStream<Set<UUID>>.Continuation?

    init(available: Bool = true, authorized: Bool = true) {
        self.available = available
        self.authorized = authorized
    }

    func requestAuthorization() async -> Bool {
        authorizationCalls += 1
        return authorized
    }

    func schedule(_ id: UUID) async throws {
        if let scheduleError { throw scheduleError }
        scheduled.append(id)
    }

    func stop(_ id: UUID) async throws {
        stopCalls.append(id)
        scheduled.removeAll { $0 == id }
    }

    func scheduledIDs() async -> Set<UUID> { Set(scheduled) }

    func updates() async -> AsyncStream<Set<UUID>> {
        AsyncStream { continuation = $0 }
    }

    func emit() { continuation?.yield(Set(scheduled)) }
}

@MainActor
final class RingControllerTests: XCTestCase {
    private let id = UUID(uuidString: "6F1C2B8E-3D4A-4E5F-9A0B-1C2D3E4F5A6B")!
    private var backend: FakeRingBackend!
    private var store: InMemoryRingStore!
    private var wall = Date(timeIntervalSince1970: 1_000)
    private var uptime = 10.0

    override func setUp() {
        super.setUp()
        backend = FakeRingBackend()
        store = InMemoryRingStore()
    }

    private func controller() -> RingController {
        RingController(backend: backend, store: store, now: { self.wall },
                       monotonic: { self.uptime })
    }

    func testRingBelowIOS26ReturnsUnsupportedOS() async {
        backend = FakeRingBackend(available: false)
        let controller = controller()
        let error = await controller.start(id)
        XCTAssertEqual(error, .unsupportedOS)
        XCTAssertEqual(backend.authorizationCalls, 0)
        XCTAssertTrue(backend.scheduled.isEmpty)
        XCTAssertNil(controller.state)
    }

    func testStartSchedulesAndPersists() async {
        let controller = controller()
        XCTAssertNil(await controller.start(id))
        XCTAssertEqual(backend.scheduled, [id])
        XCTAssertEqual(controller.state?.commandId, id)
        XCTAssertEqual(controller.state?.dismissalCount, 0)
        XCTAssertEqual(store.load()?.endAt, wall.addingTimeInterval(300))
        XCTAssertEqual(store.load()?.monotonicStart, uptime)
    }

    func testInvalidCommandIdDoesNotSchedule() async {
        let controller = controller()
        XCTAssertEqual(await controller.start(commandId: "not-a-uuid"), .invalidCommand)
        XCTAssertTrue(backend.scheduled.isEmpty)
        XCTAssertNil(store.load())
    }

    func testAuthorizationDenialSchedulesNothing() async {
        backend.authorized = false
        let controller = controller()
        XCTAssertEqual(await controller.start(id), .authorizationDenied)
        XCTAssertTrue(backend.scheduled.isEmpty)
        XCTAssertNil(store.load())
    }

    func testScheduleFailureLeavesNoActiveRing() async {
        struct Refused: Error {}
        backend.scheduleError = Refused()
        let controller = controller()
        XCTAssertEqual(await controller.start(id), .scheduleFailed)
        XCTAssertNil(store.load())
        XCTAssertNil(controller.state)
    }

    func testStopIsIdempotentAndOnlyStopsCurrentCommand() async {
        let controller = controller()
        await controller.start(id)
        await controller.stop(.parentCommand, commandId: UUID())
        XCTAssertTrue(backend.stopCalls.isEmpty)
        await controller.stop(.parentCommand)
        await controller.stop(.parentCommand)
        XCTAssertEqual(backend.stopCalls, [id])
        XCTAssertEqual(store.load()?.stopSource, .parentCommand)
    }

    func testMissingAlarmIsRearmedBeforeTheCap() async {
        let controller = controller()
        await controller.start(id)
        await controller.process(scheduledIDs: [])
        XCTAssertEqual(backend.scheduled, [id, id])
        XCTAssertEqual(controller.state?.commandId, id)
    }

    func testResumeRestoresActiveStateWithoutCountingInitialSyncAsDismissal() async {
        await controller().start(id)
        let resumed = controller()
        await resumed.resume()
        XCTAssertEqual(resumed.state?.commandId, id)
        XCTAssertEqual(resumed.state?.dismissalCount, 0)
        XCTAssertEqual(backend.scheduled, [id])
    }

    func testStoppedRingDoesNotResume() async {
        let controller = controller()
        await controller.start(id)
        await controller.stop(.pinVerified)
        let resumed = controller()
        await resumed.resume()
        XCTAssertNil(resumed.state)
        XCTAssertEqual(backend.stopCalls, [id])
        XCTAssertEqual(backend.scheduled, [])
    }
}
