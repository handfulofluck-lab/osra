import XCTest
@testable import FamilyShieldAgent
#if canImport(DeviceActivity)
import DeviceActivity
#endif

/// 5.5 PR C (#372): the rules the parent sets reach the app group, with days in the right numbering.
/// The network is stubbed here (`StubProtocol`); the live API run is `IntegrationTests/LiveAPITests` case 6.
final class RuleSyncTests: XCTestCase {

    private let defaults = UserDefaults(suiteName: AgentIdentityStore.suiteName)!
    private let base = URL(string: "https://api.example.invalid")!

    /// The shape `GET /v1/rules/:childId` returns (`toApiRuleSet`), including fields the agent ignores.
    private let rulesJSON = """
    {
      "id": "rs-1", "childId": "child-1", "updatedAt": "2026-10-24T20:00:00.000Z", "bonusMinutesToday": 0,
      "screenTime": { "dailyLimitMinutes": 120, "weekendLimitMinutes": 240, "bedtimeStart": "21:30",
                      "bedtimeEnd": "06:45", "schoolHours": { "start": "08:00", "end": "15:00", "days": [1,2,3,4,5] } },
      "webFilter": { "blockedCategories": ["gambling"], "allowedDomains": [], "blockedDomains": ["bad.example"],
                     "safeSearchEnforced": true, "youtubeRestrictedMode": "strict" },
      "appRules": [
        { "packageId": "com.example.blocked", "appName": "Blocked", "action": "block" },
        { "packageId": "com.example.limited", "appName": "Limited", "action": "time_limit", "dailyLimitMinutes": 30 },
        { "packageId": "com.example.allowed", "appName": "Allowed", "action": "allow" }
      ],
      "routines": [
        { "id": "r1", "name": "Homework", "startTime": "16:00", "endTime": "18:00", "days": [1, 7],
          "blockedApps": ["com.example.game"], "allowedApps": [] },
        { "name": "Late", "startTime": "22:00", "endTime": "02:00", "days": [5, 0, 9],
          "blockedApps": [], "allowedApps": [] }
      ],
      "alwaysAllowedApps": ["com.apple.mobilephone"],
      "socialMonitoring": {}, "contactAllowlist": []
    }
    """

    override func setUp() {
        super.setUp()
        AgentIdentityStore.secrets = InMemorySecretStore()
        AgentIdentityStore.clear()
        StubProtocol.response = nil
        StubProtocol.lastRequest = nil
    }

    override func tearDown() {
        AgentIdentityStore.clear()
        StubProtocol.response = nil
        super.tearDown()
    }

    // MARK: - Day numbering

    func testRuleDaysMapToFoundationWeekdays() {
        // Rules: 1=Mon..7=Sun. Foundation: 1=Sun..7=Sat.
        XCTAssertEqual((1...7).map { Weekday.swiftWeekday(ruleDay: $0) }, [2, 3, 4, 5, 6, 7, 1])
        XCTAssertNil(Weekday.swiftWeekday(ruleDay: 0))
        XCTAssertNil(Weekday.swiftWeekday(ruleDay: 8))
    }

    func testParsesHHMM() {
        XCTAssertEqual(parseHHMM("06:45")?.hour, 6)
        XCTAssertEqual(parseHHMM("06:45")?.minute, 45)
        XCTAssertNil(parseHHMM("24:00"))
        XCTAssertNil(parseHHMM("7"))
    }

    // MARK: - Decoding and storing

    func testDecodesTheServerShapeAndPicksTheBlockedApps() throws {
        let rules = try JSONDecoder().decode(RuleSet.self, from: Data(rulesJSON.utf8))
        XCTAssertEqual(rules.blockedBundleIdentifiers, ["com.example.blocked"], "only action == block")
        XCTAssertEqual(rules.screenTime.bedtimeStart, "21:30")
        XCTAssertEqual(rules.routines.count, 2)
    }

    func testSaveWritesTheKeysTheExtensionsRead() throws {
        let rules = try JSONDecoder().decode(RuleSet.self, from: Data(rulesJSON.utf8))
        XCTAssertTrue(RuleStore.save(rules))
        XCTAssertEqual(defaults.stringArray(forKey: "apps.blockedBundleIdentifiers"), ["com.example.blocked"])
        XCTAssertEqual(defaults.stringArray(forKey: "bedtime.blockedBundleIdentifiers"), ["com.example.blocked"])
        XCTAssertEqual(defaults.string(forKey: "rules.bedtimeStart"), "21:30")
        XCTAssertEqual(defaults.stringArray(forKey: "rules.blockedDomains"), ["bad.example"])
        let schedules = RuleStore.routineSchedules()
        XCTAssertEqual(schedules.map(\.swiftWeekdays), [[2, 1], [6]], "Mon,Sun -> 2,1; Fri -> 6; 0 and 9 dropped")
        XCTAssertEqual(schedules.first?.blockedApps, ["com.example.game"])
    }

    func testUnpairingClearsTheSyncedRules() throws {
        RuleStore.save(try JSONDecoder().decode(RuleSet.self, from: Data(rulesJSON.utf8)))
        AgentIdentityStore.clear()
        XCTAssertNil(defaults.stringArray(forKey: "apps.blockedBundleIdentifiers"))
        XCTAssertTrue(RuleStore.routineSchedules().isEmpty)
    }

    #if canImport(DeviceActivity)
    func testTheMonitorShieldsEachRoutinesOwnApps() throws {
        RuleStore.save(try JSONDecoder().decode(RuleSet.self, from: Data(rulesJSON.utf8)))
        XCTAssertEqual(FamilyShieldDeviceActivityMonitor.blockedBundleIdentifiers(for: DeviceActivityName("routine.0.2")),
                       ["com.example.game"])
        XCTAssertEqual(FamilyShieldDeviceActivityMonitor.blockedBundleIdentifiers(for: DeviceActivityName("routine.9.2")), [],
                       "an index the store does not hold shields nothing")
        XCTAssertEqual(FamilyShieldDeviceActivityMonitor.blockedBundleIdentifiers(for: DeviceActivityName("bedtime.bedtime")),
                       ["com.example.blocked"])
    }
    #endif

    // MARK: - One sync, against a stubbed server

    private func pair() {
        XCTAssertTrue(AgentIdentityStore.save(AgentIdentity(
            apiBaseURL: base, deviceToken: "device-jwt", deviceId: "dev-1",
            childId: "child-1", familyId: "fam-1", hmacSecret: "hmac")))
    }

    private var stubbedClient: RuleSyncClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return RuleSyncClient(session: URLSession(configuration: config))
    }

    func testSyncFetchesWithTheDeviceTokenAndStores() async throws {
        pair()
        StubProtocol.response = (200, Data(rulesJSON.utf8))
        let outcome = await RuleSyncer.syncNow(client: stubbedClient, enforce: false)
        guard case .synced(let rules) = outcome else { return XCTFail("got \(outcome)") }
        XCTAssertEqual(rules.blockedBundleIdentifiers, ["com.example.blocked"])
        XCTAssertEqual(StubProtocol.lastRequest?.url?.path, "/v1/rules/child-1")
        XCTAssertEqual(StubProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer device-jwt")
        XCTAssertEqual(defaults.stringArray(forKey: "apps.blockedBundleIdentifiers"), ["com.example.blocked"])
    }

    func testWithdrawnConsentClearsTheStoredRules() async throws {
        pair()
        RuleStore.save(try JSONDecoder().decode(RuleSet.self, from: Data(rulesJSON.utf8)))
        StubProtocol.response = (428, Data(#"{"error":"parental_consent_required"}"#.utf8))
        let outcome = await RuleSyncer.syncNow(client: stubbedClient, enforce: false)
        XCTAssertEqual(outcome, .consentWithdrawn)
        XCTAssertNil(defaults.stringArray(forKey: "apps.blockedBundleIdentifiers"))
    }

    func testAnyOtherFailureKeepsTheLastRules() async throws {
        pair()
        RuleStore.save(try JSONDecoder().decode(RuleSet.self, from: Data(rulesJSON.utf8)))
        StubProtocol.response = (500, Data())
        let outcome = await RuleSyncer.syncNow(client: stubbedClient, enforce: false)
        guard case .failed = outcome else { return XCTFail("got \(outcome)") }
        XCTAssertEqual(defaults.stringArray(forKey: "apps.blockedBundleIdentifiers"), ["com.example.blocked"])
    }

    func testUnpairedDoesNotCallTheServer() async {
        let outcome = await RuleSyncer.syncNow(client: stubbedClient, enforce: false)
        XCTAssertEqual(outcome, .notPaired)
        XCTAssertNil(StubProtocol.lastRequest)
    }
}

/// Answers every request with `response`, and remembers the last request.
final class StubProtocol: URLProtocol {
    static var response: (Int, Data)?
    static var lastRequest: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        let (status, body) = Self.response ?? (599, Data())
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
