import XCTest
@testable import FamilyShieldAgent

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
          "blockedApps": [], "allowedApps": ["com.example.reader"] }
      ],
      "alwaysAllowedApps": ["com.apple.mobilephone"],
      "socialMonitoring": {}, "contactAllowlist": []
    }
    """

    override func setUp() {
        super.setUp()
        AgentIdentityStore.secrets = InMemorySecretStore()
        AgentIdentityStore.clear()
        StubProtocol.reset()
    }

    override func tearDown() {
        AgentIdentityStore.clear()
        StubProtocol.reset()
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
        XCTAssertEqual(RuleStore.allowedApps(), ["com.example.allowed"], "only action == allow")
        XCTAssertEqual(RuleStore.alwaysAllowedApps(), ["com.apple.mobilephone"])
        XCTAssertEqual(defaults.string(forKey: "rules.bedtimeStart"), "21:30")
        XCTAssertEqual(defaults.stringArray(forKey: "rules.blockedDomains"), ["bad.example"])
        let schedules = RuleStore.routineSchedules()
        XCTAssertEqual(schedules.map(\.swiftWeekdays), [[2, 1], [6]], "Mon,Sun -> 2,1; Fri -> 6; 0 and 9 dropped")
        XCTAssertEqual(schedules.first?.blockedApps, ["com.example.game"])
        XCTAssertEqual(schedules.last?.allowedApps, ["com.example.reader"])
    }

    func testUnpairingClearsTheSyncedRules() throws {
        RuleStore.save(try JSONDecoder().decode(RuleSet.self, from: Data(rulesJSON.utf8)))
        AgentIdentityStore.clear()
        XCTAssertNil(defaults.stringArray(forKey: "apps.blockedBundleIdentifiers"))
        XCTAssertTrue(RuleStore.routineSchedules().isEmpty)
    }

    // MARK: - What a running interval shields (ShieldPolicy)

    private let homework = RuleStore.RoutineSchedule(name: "Homework", startTime: "16:00", endTime: "18:00",
                                                    swiftWeekdays: [2, 1], blockedApps: ["com.example.game"], allowedApps: [])
    private let lateReading = RuleStore.RoutineSchedule(name: "Late", startTime: "22:00", endTime: "02:00",
                                                       swiftWeekdays: [6], blockedApps: [], allowedApps: ["com.example.reader"])

    private func decide(_ activity: String, weekday: Int) -> ShieldPolicy {
        ShieldPolicy.decide(activity: activity, weekday: weekday, alwaysAllowed: ["com.example.always"],
                            allowed: ["com.example.allowed"], routines: [homework, lateReading])
    }

    func testBedtimeShieldsEverythingExceptTheAllowedAppsAndThePhone() {
        // Android's RuleEngine step 5: bedtime blocks every app that is not allowed. Not the blocked list,
        // which is shielded all day anyway.
        XCTAssertEqual(decide("bedtime.bedtime", weekday: 4),
                       .allExcept(["com.example.always", "com.example.allowed", "com.apple.mobilephone"]))
    }

    func testAnAllowListRoutineShieldsEverythingElse() {
        XCTAssertEqual(decide("routine.1", weekday: 6),
                       .allExcept(["com.example.always", "com.example.allowed", "com.apple.mobilephone", "com.example.reader"]))
    }

    func testABlockListRoutineShieldsOnlyItsApps() {
        XCTAssertEqual(decide("routine.0", weekday: 2), .only(["com.example.game"]))
        XCTAssertEqual(decide("routine.0", weekday: 1), .only(["com.example.game"]))
    }

    func testARoutineShieldsNothingOnADayItDoesNotRun() {
        XCTAssertEqual(decide("routine.0", weekday: 4), .none, "Homework runs Mon and Sun (2, 1), not Wed")
        // Late runs on Friday (6) from 22:00 to 02:00. The interval that starts on Saturday night is not its.
        XCTAssertEqual(decide("routine.1", weekday: 7), .none)
    }

    func testAnUnknownActivityShieldsNothing() {
        XCTAssertEqual(decide("routine.9", weekday: 2), .none)
        XCTAssertEqual(decide("routine.0.2", weekday: 2), .none, "the old per-weekday names are not honoured")
        XCTAssertEqual(decide("something", weekday: 2), .none)
    }

    func testThePolicyReadsTheStoredRules() throws {
        RuleStore.save(try JSONDecoder().decode(RuleSet.self, from: Data(rulesJSON.utf8)))
        XCTAssertEqual(ShieldPolicy.current(activity: "routine.0", weekday: 2), .only(["com.example.game"]))
        XCTAssertEqual(ShieldPolicy.current(activity: "bedtime.bedtime", weekday: 2),
                       .allExcept(["com.apple.mobilephone", "com.example.allowed"]), "duplicates collapse")
    }

    // MARK: - Registering and stopping activities

    func testOneActivityPerRoutineWhateverItsDays() {
        let everyDay = RuleStore.RoutineSchedule(name: "Every day", startTime: "08:00", endTime: "09:00",
                                                 swiftWeekdays: Array(1...7), blockedApps: ["x"], allowedApps: [])
        XCTAssertEqual(RoutinePlan.activityNames(for: [everyDay]), ["routine.0"], "seven days, one activity")
        XCTAssertEqual(RoutinePlan.activityNames(for: [everyDay, homework, lateReading]),
                       ["routine.0", "routine.1", "routine.2"])
    }

    func testStoppingClearsEachShieldBeforeMonitoringStops() {
        var calls: [String] = []
        ActivityTeardown.stop(["bedtime.bedtime", "routine.0"],
                              clearStore: { calls.append("clear \($0)") },
                              stopMonitoring: { calls.append("stop \($0.joined(separator: ","))") })
        XCTAssertEqual(calls, ["clear bedtime.bedtime", "clear routine.0", "stop bedtime.bedtime,routine.0"])
    }


    // MARK: - One sync, against a stubbed server

    private func pair() {
        XCTAssertTrue(AgentIdentityStore.save(AgentIdentity(
            apiBaseURL: base, deviceToken: "device-jwt", deviceId: "dev-1",
            childId: "child-1", familyId: "fam-1", hmacSecret: "hmac")))
    }

    private var stubbedClient: RuleSyncClient { RuleSyncClient(session: StubProtocol.session) }

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

/// Answers every request with `responder` (or `response`), and records each request with its body.
final class StubProtocol: URLProtocol {
    static var response: (Int, Data)?
    static var responder: ((URLRequest) -> (Int, Data))?
    /// Response headers for every answer (`X-Push-Token`, #383).
    static var headers: [String: String]?
    static var requests: [(request: URLRequest, body: Data)] = []
    static var lastRequest: URLRequest? {
        get { requests.last?.request }
        set { if newValue == nil { requests = [] } }
    }

    static func reset() {
        response = nil
        responder = nil
        headers = nil
        requests = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append((request, Self.body(of: request)))
        let (status, body) = Self.responder?(request) ?? Self.response ?? (599, Data())
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: Self.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// URLSession moves the body into a stream before a protocol sees it.
    private static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }

    /// A session whose every request is answered by this protocol.
    static var session: URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: config)
    }
}
