import XCTest
import CoreLocation
@testable import FamilyShieldAgent

/// 5.5 PR E (#372): location on the Android contract, against a stubbed server (`StubProtocol`) and a fake
/// [LocationSource], so no test touches Core Location. The live run is `IntegrationTests/LiveAPITests` case 9.
@MainActor
final class LocationTests: XCTestCase {

    private let base = URL(string: "https://api.example.invalid")!
    private var source: FakeLocationSource!
    private var controller: LocationController!

    override func setUp() async throws {
        try await super.setUp()
        AgentIdentityStore.secrets = InMemorySecretStore()
        AgentIdentityStore.clear()
        LocationBuffer.clear()
        StubProtocol.reset()
        source = FakeLocationSource()
        controller = LocationController(source: source, client: LocationClient(session: StubProtocol.session))
    }

    override func tearDown() async throws {
        AgentIdentityStore.clear()
        LocationBuffer.clear()
        StubProtocol.reset()
        try await super.tearDown()
    }

    private func pair() {
        XCTAssertTrue(AgentIdentityStore.save(AgentIdentity(
            apiBaseURL: base, deviceToken: "device-jwt", deviceId: "dev-1",
            childId: "child-1", familyId: "fam-1", hmacSecret: "hmac")))
    }

    private func ping(_ i: Int, at date: Date = Date(timeIntervalSince1970: 1_790_000_000)) -> LocationPing {
        LocationPing(lat: 25 + Double(i) / 1000, lng: 51.5, accuracyM: 65, timestamp: date.addingTimeInterval(Double(i)))
    }

    private func location(ageSeconds: TimeInterval, now: Date = Date()) -> CLLocation {
        CLLocation(coordinate: CLLocationCoordinate2D(latitude: 25.2854, longitude: 51.531), altitude: 0,
                   horizontalAccuracy: 48, verticalAccuracy: -1, timestamp: now.addingTimeInterval(-ageSeconds))
    }

    private func body(of request: (request: URLRequest, body: Data)?) -> [String: Any]? {
        guard let request else { return nil }
        return try? JSONSerialization.jsonObject(with: request.body) as? [String: Any]
    }

    // MARK: - The grant

    func testTheGrantMapsAlwaysToBackgroundWhenInUseToWhileInUseAndTheRestToNone() {
        XCTAssertEqual(LocationGrant.from(.authorizedAlways), .background)
        XCTAssertEqual(LocationGrant.from(.authorizedWhenInUse), .whileInUse)
        for status: CLAuthorizationStatus in [.notDetermined, .restricted, .denied] {
            XCTAssertEqual(LocationGrant.from(status), .noAccess, "\(status.rawValue)")
        }
        XCTAssertEqual(LocationGrant.background.rawValue, "background")
        XCTAssertEqual(LocationGrant.whileInUse.rawValue, "while_in_use")
        XCTAssertEqual(LocationGrant.noAccess.rawValue, "none")
    }

    func testTheTelemetryUploadCarriesTheGrant() async throws {
        pair()
        source.authorizationStatus = .authorizedWhenInUse
        StubProtocol.response = (202, Data(#"{"accepted":true}"#.utf8))
        let status = await controller.reportGrant()
        XCTAssertEqual(status, 202)
        let request = try XCTUnwrap(StubProtocol.requests.first)
        XCTAssertEqual(request.request.url?.path, "/v1/devices/dev-1/telemetry")
        XCTAssertEqual(request.request.httpMethod, "POST")
        XCTAssertEqual(request.request.value(forHTTPHeaderField: "Authorization"), "Bearer device-jwt")
        XCTAssertEqual(body(of: request)?["locationGrant"] as? String, "while_in_use")
    }

    func testWhenInUseAsksForAlwaysAndTheChangeIsReported() async throws {
        pair()
        StubProtocol.response = (200, Data("{}".utf8))
        source.authorizationStatus = .authorizedWhenInUse
        source.onAuthorizationChange?(.authorizedWhenInUse)
        XCTAssertEqual(source.alwaysRequests, 1, "significant-change monitoring needs Always")
        XCTAssertEqual(source.startCalls, 1)
        for _ in 0..<100 where StubProtocol.requests.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(body(of: StubProtocol.requests.first)?["locationGrant"] as? String, "while_in_use")
    }

    // MARK: - Upload

    func testTheBodyIsTheEnvelopeWithISOTimestampsAndAccuracy() async throws {
        pair()
        StubProtocol.response = (201, Data("{}".utf8))
        let sent = ping(0)
        LocationBuffer.append([sent])
        let outcome = await controller.flush()
        XCTAssertEqual(outcome, .stored)
        let request = try XCTUnwrap(StubProtocol.requests.first)
        XCTAssertEqual(request.request.url?.path, "/v1/location/ping")
        XCTAssertEqual(request.request.value(forHTTPHeaderField: "Authorization"), "Bearer device-jwt")
        let json = try XCTUnwrap(body(of: request))
        XCTAssertEqual(json["deviceId"] as? String, "dev-1")
        XCTAssertEqual(json["childId"] as? String, "child-1")
        let item = try XCTUnwrap((json["pings"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(item.keys), ["lat", "lng", "accuracyM", "timestamp"])
        XCTAssertEqual(item["lat"] as? Double, sent.lat)
        XCTAssertEqual(item["lng"] as? Double, sent.lng)
        XCTAssertEqual(item["accuracyM"] as? Double, 65)
        let stamp = try XCTUnwrap(item["timestamp"] as? String, "ISO 8601 text, not epoch seconds")
        XCTAssertTrue(stamp.hasSuffix("Z"), "UTC, as the server's z.string().datetime() requires: \(stamp)")
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        XCTAssertEqual(try XCTUnwrap(iso.date(from: stamp)).timeIntervalSince1970, sent.timestamp.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertTrue(LocationBuffer.load().isEmpty, "a stored batch leaves the buffer")
    }

    func testA428StopsCollectingAndEmptiesTheBuffer() async {
        pair()
        source.monitoring = true
        LocationBuffer.append([ping(0), ping(1)])
        StubProtocol.response = (428, Data(#"{"error":"parental_consent_required"}"#.utf8))
        let outcome = await controller.flush()
        XCTAssertEqual(outcome, .consentWithdrawn)
        XCTAssertFalse(source.monitoring, "consent withdrawn: collection stops (ADR-0008 §2b)")
        XCTAssertTrue(LocationBuffer.load().isEmpty)
    }

    func testA400DropsTheBatchSoOneBadPingCannotWedgeTheBuffer() async {
        pair()
        LocationBuffer.append([ping(0)])
        StubProtocol.response = (400, Data("{}".utf8))
        let outcome = await controller.flush()
        XCTAssertEqual(outcome, .rejected(status: 400))
        XCTAssertTrue(LocationBuffer.load().isEmpty)
    }

    func testA5xxA429AndA401KeepTheBuffer() async {
        pair()
        let kept = [ping(0), ping(1)]
        LocationBuffer.append(kept)
        for (status, expected) in [(503, LocationUploadOutcome.retryLater(status: 503)),
                                   (429, .retryLater(status: 429)),
                                   (401, .unauthorized)] {
            StubProtocol.response = (status, Data())
            let outcome = await controller.flush()
            XCTAssertEqual(outcome, expected)
            XCTAssertEqual(LocationBuffer.load(), kept, "kept after \(status)")
        }
        XCTAssertTrue(source.monitoring == false && source.stopCalls == 0, "only a 428 stops collection")
    }

    func testTheBufferHoldsFiveHundredAndDropsTheOldestFirst() {
        LocationBuffer.append((0..<450).map { ping($0) })
        LocationBuffer.append((450..<520).map { ping($0) })
        let held = LocationBuffer.load()
        XCTAssertEqual(held.count, LocationBuffer.capacity)
        XCTAssertEqual(LocationBuffer.capacity, 500, "the server's maximum batch")
        XCTAssertEqual(held.first, ping(20), "the 20 oldest went first")
        XCTAssertEqual(held.last, ping(519))
    }

    func testAPingAddedDuringAnUploadStays() {
        let sent = [ping(0)]
        LocationBuffer.append(sent)
        LocationBuffer.append([ping(1)])
        LocationBuffer.remove(sent)
        XCTAssertEqual(LocationBuffer.load(), [ping(1)])
    }

    func testAFlushRemovesOnlyTheBatchItSentSoAFixRecordedDuringTheUploadStays() async {
        pair()
        LocationBuffer.append([ping(0)])
        let late = ping(1)
        StubProtocol.responder = { _ in
            LocationBuffer.append([late]) // a new fix arrives while the batch is in flight
            return (201, Data("{}".utf8))
        }
        let outcome = await controller.flush()
        XCTAssertEqual(outcome, .stored)
        XCTAssertEqual(LocationBuffer.load(), [late], "only the sent batch is removed; the late fix waits for the next upload")
    }

    func testANewFixIsBufferedAndUploaded() async throws {
        pair()
        StubProtocol.response = (201, Data("{}".utf8))
        await controller.record([location(ageSeconds: 0)])
        XCTAssertEqual(StubProtocol.requests.first?.request.url?.path, "/v1/location/ping")
        XCTAssertTrue(LocationBuffer.load().isEmpty)
    }

    func testUnpairedRecordsNothing() async {
        await controller.record([location(ageSeconds: 0)])
        XCTAssertTrue(LocationBuffer.load().isEmpty)
        XCTAssertTrue(StubProtocol.requests.isEmpty)
    }

    // MARK: - Starting and stopping

    func testMonitoringStartsOnlyWhenPairedAndAllowed() {
        source.authorizationStatus = .authorizedAlways
        controller.startIfAllowed()
        XCTAssertEqual(source.startCalls, 0, "not paired")
        pair()
        source.authorizationStatus = .denied
        controller.startIfAllowed()
        XCTAssertEqual(source.startCalls, 0, "no permission")
        source.authorizationStatus = .authorizedAlways
        controller.startIfAllowed()
        XCTAssertEqual(source.startCalls, 1)
    }

    func testTheRuleSyncDrivesCollection() throws {
        pair()
        LocationBuffer.append([ping(0)])
        let minimal = #"{"screenTime":{"dailyLimitMinutes":0,"weekendLimitMinutes":0,"bedtimeStart":"21:00","bedtimeEnd":"07:00","schoolHours":{"start":"08:00","end":"15:00","days":[]}},"webFilter":{"blockedCategories":[],"allowedDomains":[],"blockedDomains":[],"safeSearchEnforced":false},"appRules":[],"routines":[],"alwaysAllowedApps":[]}"#
        controller.apply(.synced(try JSONDecoder().decode(RuleSet.self, from: Data(minimal.utf8))))
        XCTAssertTrue(source.monitoring)
        controller.apply(.consentWithdrawn)
        XCTAssertFalse(source.monitoring)
        XCTAssertTrue(LocationBuffer.load().isEmpty)
    }

    // MARK: - locate_now

    func testLocateNowAcksOkFreshOnlyAfterTheServerStoredThePoint() async throws {
        pair()
        source.nextFix = location(ageSeconds: 0)
        StubProtocol.response = (201, Data("{}".utf8))
        let ack = await controller.locateNow()
        XCTAssertEqual(ack, .ok(fix: "fresh"))
        XCTAssertEqual(source.fixRequests, 1)
        XCTAssertEqual(StubProtocol.requests.count, 1, "the point was uploaded before the ack")
    }

    func testLocateNowSendsNoAckWhenTheUploadFails() async {
        pair()
        source.nextFix = location(ageSeconds: 0)
        StubProtocol.response = (503, Data())
        let ack = await controller.locateNow()
        XCTAssertNil(ack, "no ack: the server offers the command again in 120 s (#231)")
        XCTAssertEqual(LocationBuffer.load().count, 1, "the point waits for the next upload")
    }

    func testLocateNowFallsBackToAFixUnderFiveMinutesOld() async {
        pair()
        let now = Date()
        source.nextFix = nil
        source.lastFix = location(ageSeconds: 4 * 60, now: now)
        StubProtocol.response = (201, Data("{}".utf8))
        let cached = await controller.locateNow(now: now)
        XCTAssertEqual(cached, .ok(fix: "cached"))

        StubProtocol.reset()
        source.lastFix = location(ageSeconds: 6 * 60, now: now)
        let stale = await controller.locateNow(now: now)
        XCTAssertEqual(stale, .failed(reason: "location_unavailable"))
        XCTAssertTrue(StubProtocol.requests.isEmpty)
    }

    func testAFixCoreLocationAlreadyHeldIsReportedCachedAndAStaleOneIsNoAnswer() async {
        pair()
        let now = Date()
        StubProtocol.response = (201, Data("{}".utf8))
        source.nextFix = location(ageSeconds: 30, now: now)
        let recent = await controller.locateNow(now: now)
        XCTAssertEqual(recent, .ok(fix: "fresh"), "under a minute old is fresh")

        source.nextFix = location(ageSeconds: 120, now: now)
        let held = await controller.locateNow(now: now)
        XCTAssertEqual(held, .ok(fix: "cached"), "requestLocation() answered with a fix it already held (Claude on #390)")

        StubProtocol.reset()
        source.nextFix = location(ageSeconds: 6 * 60, now: now)
        source.lastFix = nil
        let stale = await controller.locateNow(now: now)
        XCTAssertEqual(stale, .failed(reason: "location_unavailable"), "over five minutes is not where the child is now")
        XCTAssertTrue(StubProtocol.requests.isEmpty)
    }

    // MARK: - One request for a fix at a time (Claude on #390)

    func testATimerFromAnEarlierRequestDoesNotEndALaterOne() async throws {
        let oneShot = OneShotFix()
        let first = Task { await oneShot.wait(timeout: 0.3) {} }
        try await Task.sleep(nanoseconds: 50_000_000)
        let second = Task { await oneShot.wait(timeout: 5) {} }
        let superseded = await first.value
        XCTAssertNil(superseded, "a newer request supersedes the older one, which falls back to the cached fix")
        // Past the first request's 0.3 s timer: the second must still be waiting for its own fix.
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertTrue(oneShot.isWaiting, "the earlier request's timer ended the later one")
        let fix = location(ageSeconds: 0)
        oneShot.resolve(fix)
        let answered = await second.value
        XCTAssertEqual(answered, fix)
    }

    func testARequestEndsOnItsOwnTimeoutAndAFixAnswersItOnce() async {
        let oneShot = OneShotFix()
        var started = 0
        let timedOut = await oneShot.wait(timeout: 0.1) { started += 1 }
        XCTAssertNil(timedOut)
        XCTAssertEqual(started, 1)
        XCTAssertFalse(oneShot.isWaiting)
        oneShot.resolve(location(ageSeconds: 0)) // nothing waiting: ignored, no double resume
    }

    func testLocateNowRefusesWithTheAndroidReasons() async {
        pair()
        source.nextFix = location(ageSeconds: 0)
        let cases: [(CLAuthorizationStatus, String)] = [
            (.authorizedWhenInUse, "background_location_missing"),
            (.denied, "location_permission_missing"),
            (.notDetermined, "location_permission_missing"),
            (.restricted, "location_permission_missing"),
        ]
        for (status, reason) in cases {
            source.authorizationStatus = status
            let ack = await controller.locateNow()
            XCTAssertEqual(ack, .failed(reason: reason), "\(status.rawValue)")
        }
        XCTAssertEqual(source.fixRequests, 0)
        XCTAssertTrue(StubProtocol.requests.isEmpty)
    }

    // MARK: - locate_now in the drain

    func testTheDrainAcksLocateNowWithTheFixAndOneLocatorCallServesSeveral() async {
        pair()
        let locator = FakeLocator(answer: .ok(fix: "cached"))
        StubProtocol.responder = { request in
            request.url?.path.hasSuffix("/commands") == true
                ? (200, try! JSONSerialization.data(withJSONObject: [["id": "c1", "type": "locate_now"], ["id": "c2", "type": "locate_now"]]))
                : (200, Data("{}".utf8))
        }
        let result = await CommandDrainer.drainNow(client: CommandClient(session: StubProtocol.session),
                                                   tokenSession: StubProtocol.session, locator: locator) { .notPaired }
        XCTAssertEqual(locator.calls, 1)
        XCTAssertEqual(result.handled, ["locate_now", "locate_now"])
        let acks = ackBodies()
        XCTAssertEqual(acks.map { $0["status"] as? String }, ["ok", "ok"])
        XCTAssertEqual((acks.first?["detail"] as? [String: String])?["fix"], "cached")
    }

    func testTheDrainAcksARefusalAndSkipsTheAckWhenThePointWasNotStored() async {
        pair()
        StubProtocol.responder = { request in
            request.url?.path.hasSuffix("/commands") == true
                ? (200, try! JSONSerialization.data(withJSONObject: [["id": "c1", "type": "locate_now"]]))
                : (200, Data("{}".utf8))
        }
        _ = await CommandDrainer.drainNow(client: CommandClient(session: StubProtocol.session), tokenSession: StubProtocol.session,
                                          locator: FakeLocator(answer: .failed(reason: "background_location_missing"))) { .notPaired }
        XCTAssertEqual(ackBodies().first?["status"] as? String, "failed")
        XCTAssertEqual((ackBodies().first?["detail"] as? [String: String])?["reason"], "background_location_missing")

        StubProtocol.requests = []
        _ = await CommandDrainer.drainNow(client: CommandClient(session: StubProtocol.session), tokenSession: StubProtocol.session,
                                          locator: FakeLocator(answer: nil)) { .notPaired }
        XCTAssertTrue(ackBodies().isEmpty, "not stored: no ack, so the command is offered again")
    }

    func testLocateNowIsNoLongerRefusedAsUnsupported() {
        XCTAssertEqual(CommandAction.forType("locate_now"), .locateNow)
    }

    private func ackBodies() -> [[String: Any]] {
        StubProtocol.requests.filter { $0.request.url?.path.hasSuffix("/ack") == true }
            .compactMap { try? JSONSerialization.jsonObject(with: $0.body) as? [String: Any] }
    }
}

final class FakeLocationSource: LocationSource {
    var authorizationStatus: CLAuthorizationStatus = .authorizedAlways
    var lastFix: CLLocation?
    var onLocations: (([CLLocation]) -> Void)?
    var onAuthorizationChange: ((CLAuthorizationStatus) -> Void)?
    var monitoring = false
    var startCalls = 0
    var stopCalls = 0
    var alwaysRequests = 0
    var whenInUseRequests = 0
    var nextFix: CLLocation?
    var fixRequests = 0

    func startMonitoring() { monitoring = true; startCalls += 1 }
    func stopMonitoring() { monitoring = false; stopCalls += 1 }
    func requestOneFix(timeout: TimeInterval) async -> CLLocation? { fixRequests += 1; return nextFix }
    func requestWhenInUse() { whenInUseRequests += 1 }
    func requestAlways() { alwaysRequests += 1 }
}

final class FakeLocator: LocateNowHandling {
    let answer: LocateAck?
    var calls = 0
    init(answer: LocateAck?) { self.answer = answer }
    func locateNow() async -> LocateAck? { calls += 1; return answer }
}
