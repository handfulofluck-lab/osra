import Foundation
import CoreLocation
import os

/// Location for the iOS child agent (5.5 PR E, #372), on the contract the Android agent already uses:
/// `POST /v1/location/ping` with the device token, and the location grant in the telemetry upload, so the
/// server can fail a `locate_now` the phone cannot answer (`lib/locationGrant.ts`). No server change.
///
/// Collection is significant-change monitoring only: no continuous GPS and no `location` background mode.
/// It is coarser than Android (every 30 s moving, 5 min still), and it relaunches a suspended or terminated
/// app on its own (`OSRAAgentAppDelegate`).

/// What the agent reports as `locationGrant`. Reduced accuracy is not a fourth state: the pings carry
/// their real `accuracyM`.
public enum LocationGrant: String, Equatable {
    case background
    case whileInUse = "while_in_use"
    case noAccess = "none"

    public static func from(_ status: CLAuthorizationStatus) -> LocationGrant {
        switch status {
        case .authorizedAlways: return .background
        case .authorizedWhenInUse: return .whileInUse
        default: return .noAccess
        }
    }
}

public struct LocationPing: Codable, Equatable {
    public var lat: Double
    public var lng: Double
    public var accuracyM: Double
    public var timestamp: Date

    public init(lat: Double, lng: Double, accuracyM: Double, timestamp: Date) {
        self.lat = lat
        self.lng = lng
        self.accuracyM = accuracyM
        self.timestamp = timestamp
    }

    public init(_ location: CLLocation) {
        self.init(lat: location.coordinate.latitude, lng: location.coordinate.longitude,
                  accuracyM: max(0, location.horizontalAccuracy), timestamp: location.timestamp)
    }
}

/// Pings not yet stored by the server, in the app group so they survive a relaunch. Capped at the
/// server's batch maximum, oldest dropped first.
public enum LocationBuffer {
    public static let capacity = 500
    static let key = "location.buffer"

    private static var defaults: UserDefaults? { UserDefaults(suiteName: AgentIdentityStore.suiteName) }

    public static func load() -> [LocationPing] {
        guard let data = defaults?.data(forKey: key),
              let pings = try? JSONDecoder().decode([LocationPing].self, from: data) else { return [] }
        return pings
    }

    public static func append(_ pings: [LocationPing]) {
        save(Array((load() + pings).suffix(capacity)))
    }

    /// Removes what the server stored; pings added during the upload stay.
    public static func remove(_ sent: [LocationPing]) {
        save(load().filter { !sent.contains($0) })
    }

    public static func clear() {
        defaults?.removeObject(forKey: key)
    }

    private static func save(_ pings: [LocationPing]) {
        guard let data = try? JSONEncoder().encode(pings) else { return }
        defaults?.set(data, forKey: key)
    }
}

/// How the server answered an upload, and what that means for the buffer.
public enum LocationUploadOutcome: Equatable {
    /// 200/201: stored; the batch leaves the buffer.
    case stored
    /// 428: consent was withdrawn; collection stops and the buffer is emptied (ADR-0008 §2b).
    case consentWithdrawn
    /// 401: kept. A `device_revoked` 401 has already unpaired the phone (#690), which empties the buffer.
    case unauthorized
    /// 400 and the other refusals: the batch is dropped, so one bad ping cannot wedge the buffer.
    case rejected(status: Int)
    /// 429, 5xx or offline: kept for the next event.
    case retryLater(status: Int)
}

public struct LocationClient {
    private let session: URLSession
    private static let logger = Logger(subsystem: "com.osratech.child", category: "Location")

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// The body `location.ts` validates: the envelope with the device's ids, and ISO 8601 UTC timestamps.
    static func pingBody(_ identity: AgentIdentity, _ pings: [LocationPing]) -> [String: Any] {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return [
            "deviceId": identity.deviceId,
            "childId": identity.childId,
            "pings": pings.map { ["lat": $0.lat, "lng": $0.lng, "accuracyM": $0.accuracyM, "timestamp": iso.string(from: $0.timestamp)] },
        ]
    }

    public func upload(_ identity: AgentIdentity, _ pings: [LocationPing]) async -> LocationUploadOutcome {
        var request = URLRequest(url: identity.apiBaseURL.appendingPathComponent("v1/location/ping"))
        request.httpMethod = "POST"
        request.httpBody = try? JSONSerialization.data(withJSONObject: Self.pingBody(identity, pings))
        let status = await send(&request, identity)
        switch status {
        case 200, 201: return .stored
        case 428: return .consentWithdrawn
        case 401: return .unauthorized
        case 429, 0, 500...: return .retryLater(status: status)
        default:
            Self.logger.error("location batch of \(pings.count) refused with \(status); dropped")
            return .rejected(status: status)
        }
    }

    /// The telemetry body: the grant when known, and #475's applied rules version once the phone has applied
    /// a rule set. A field that is nil is left out, never sent as 0 (the server refuses 0).
    static func telemetryBody(grant: LocationGrant?, appliedRulesVersion: Int?,
                              capabilities: [String: Any]? = nil) -> [String: Any] {
        var body: [String: Any] = [:]
        if let grant { body["locationGrant"] = grant.rawValue }
        if let appliedRulesVersion { body["appliedRulesVersion"] = appliedRulesVersion }
        // ADR-0034 A6 / ADR-0037: the capability report rides the same upload.
        if let capabilities { body["capabilities"] = capabilities }
        return body
    }

    /// `POST /v1/devices/:id/telemetry {"locationGrant", "appliedRulesVersion"?}`; every field is optional.
    @discardableResult
    public func reportGrant(_ identity: AgentIdentity, _ grant: LocationGrant,
                            appliedRulesVersion: Int? = RuleStore.appliedRulesVersion(),
                            capabilities: CapabilityReport? = nil) async -> Int {
        await postTelemetry(identity, Self.telemetryBody(grant: grant, appliedRulesVersion: appliedRulesVersion,
                                                         capabilities: capabilities?.json),
                            clientHeader: capabilities?.clientHeader)
    }

    /// #475: right after a rule set was applied, so the parent's "not picked up yet" line clears.
    @discardableResult
    public func reportAppliedRulesVersion(_ identity: AgentIdentity, _ version: Int) async -> Int {
        await postTelemetry(identity, Self.telemetryBody(grant: nil, appliedRulesVersion: version))
    }

    private func postTelemetry(_ identity: AgentIdentity, _ body: [String: Any], clientHeader: String? = nil) async -> Int {
        var request = URLRequest(url: identity.apiBaseURL.appendingPathComponent("v1/devices")
            .appendingPathComponent(identity.deviceId).appendingPathComponent("telemetry"))
        request.httpMethod = "POST"
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        // ADR-0034 A3: a hint for the version gate and support, never a control.
        if let clientHeader { request.setValue(clientHeader, forHTTPHeaderField: "X-OSRA-Client") }
        return await send(&request, identity)
    }

    private func send(_ request: inout URLRequest, _ identity: AgentIdentity) async -> Int {
        request.setValue("Bearer \(identity.deviceToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 20
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            // #690: a removed phone stops being paired here too; the 401 still answers the caller as before.
            DeviceRevocation.handle(status: status, body: data)
            return status
        } catch {
            Self.logger.error("location request failed: \(error.localizedDescription, privacy: .public)")
            return 0
        }
    }
}

/// Where fixes come from. The real one wraps `CLLocationManager`; the tests use a fake, so they never touch
/// Core Location. Called from the main-actor [LocationController].
public protocol LocationSource: AnyObject {
    var authorizationStatus: CLAuthorizationStatus { get }
    /// The system's last fix, if any (`CLLocationManager.location`).
    var lastFix: CLLocation? { get }
    var onLocations: (([CLLocation]) -> Void)? { get set }
    var onAuthorizationChange: ((CLAuthorizationStatus) -> Void)? { get set }
    func startMonitoring()
    func stopMonitoring()
    /// One fix at about 100 m, or nil when none arrives within `timeout`.
    func requestOneFix(timeout: TimeInterval) async -> CLLocation?
    func requestWhenInUse()
    func requestAlways()
}

/// What the Status screen's location button does (5.5, #372). iOS shows the When In Use prompt once and the
/// Always upgrade once; after a denial, or once the upgrade prompt was used, only Settings can change it, so
/// the button opens Settings instead of doing nothing (iPhone 13 run, 11 Nov).
public enum LocationPermissionAction: Equatable {
    /// Always is granted: no button.
    case hidden
    case askWhenInUse
    case askAlways
    case openSettings

    public static func of(_ status: CLAuthorizationStatus, alwaysPromptUsed: Bool) -> LocationPermissionAction {
        switch status {
        case .notDetermined: return .askWhenInUse
        case .authorizedWhenInUse: return alwaysPromptUsed ? .openSettings : .askAlways
        case .authorizedAlways: return .hidden
        default: return .openSettings // .denied, .restricted
        }
    }

    /// The button's label; nil hides it.
    public var buttonTitle: String? {
        switch self {
        case .hidden: return nil
        case .askWhenInUse, .askAlways: return L10n.tr("location_allow")
        case .openSettings: return L10n.tr("location_open_settings")
        }
    }
}

/// The answer to a `locate_now`, or nil for no ack (the server re-offers an unacked command after 120 s).
public enum LocateAck: Equatable {
    case ok(fix: String)
    case failed(reason: String)

    /// The refusal strings the Android agent acks with (#132); there is one vocabulary.
    public static let permissionMissing = "location_permission_missing"
    public static let backgroundMissing = "background_location_missing"
    public static let unavailable = "location_unavailable"
}

@MainActor
public final class LocationController {
    public static let shared = LocationController(source: CoreLocationSource())

    /// A cached fix older than this is not an answer to "where is the child now", as Android's
    /// `MAX_CACHED_AGE_MS`.
    public static let maxCachedAge: TimeInterval = 5 * 60
    /// A fix `requestLocation()` returns older than this is reported `cached`, not `fresh`.
    public static let maxFreshAge: TimeInterval = 60
    public static let fixTimeout: TimeInterval = 10
    /// Runs an upload so it can finish if iOS suspends the app; the host app wraps it in
    /// `beginBackgroundTask` (a package test has no UIApplication to ask).
    public static var backgroundTask: (_ name: String, _ work: @escaping () async -> Void) async -> Void = { _, work in await work() }

    let source: LocationSource
    let client: LocationClient
    private static let logger = Logger(subsystem: "com.osratech.child", category: "Location")

    public init(source: LocationSource, client: LocationClient = LocationClient()) {
        self.source = source
        self.client = client
        source.onLocations = { [weak self] locations in
            guard let self else { return }
            Task { @MainActor in await self.record(locations) }
        }
        source.onAuthorizationChange = { [weak self] status in
            guard let self else { return }
            // When In Use first, then the upgrade to Always, which significant-change monitoring needs.
            // iOS shows that upgrade once; after it, the button opens Settings.
            if status == .authorizedWhenInUse && !Self.alwaysPromptUsed { self.askAlways() }
            self.startIfAllowed()
            Task { @MainActor in await self.reportGrant() }
        }
    }

    public var grant: LocationGrant { LocationGrant.from(source.authorizationStatus) }

    /// Starts significant-change monitoring when paired and allowed; at launch, after pairing, after a sync.
    public func startIfAllowed() {
        guard AgentIdentityStore.load() != nil, grant != .noAccess else { return }
        source.startMonitoring()
    }

    /// What the location button does now.
    public var permissionAction: LocationPermissionAction {
        .of(source.authorizationStatus, alwaysPromptUsed: Self.alwaysPromptUsed)
    }

    /// Opens this app's page in Settings; the host app sets it (a package test has no UIApplication).
    public var openSettings: () -> Void = {}

    /// The button: asks for When In Use, then for Always once; after a denial or a used Always prompt, opens
    /// Settings, because iOS no longer shows the prompt.
    public func requestPermission() {
        switch permissionAction {
        case .askWhenInUse: source.requestWhenInUse()
        case .askAlways: askAlways()
        case .openSettings: openSettings()
        case .hidden: break
        }
    }

    private func askAlways() {
        Self.alwaysPromptUsed = true
        source.requestAlways()
    }

    static let alwaysPromptKey = "location.alwaysPromptUsed"

    /// Whether the one-time Always prompt was shown, in the app group so it survives a relaunch.
    static var alwaysPromptUsed: Bool {
        get { UserDefaults(suiteName: AgentIdentityStore.suiteName)?.bool(forKey: alwaysPromptKey) ?? false }
        set { UserDefaults(suiteName: AgentIdentityStore.suiteName)?.set(newValue, forKey: alwaysPromptKey) }
    }

    /// Consent was withdrawn (a 428 from the ping or the rules): stop collecting and drop what is buffered.
    public func stopForConsent() {
        source.stopMonitoring()
        LocationBuffer.clear()
    }

    func record(_ locations: [CLLocation]) async {
        guard !locations.isEmpty, AgentIdentityStore.load() != nil else { return }
        LocationBuffer.append(locations.map(LocationPing.init))
        await Self.backgroundTask("location-upload") { [weak self] in await self?.flush() }
    }

    /// Follows the rule sync: a withdrawn consent stops collection, a successful sync (re)starts it.
    public func apply(_ outcome: RuleSyncer.Outcome) {
        switch outcome {
        case .consentWithdrawn: stopForConsent()
        case .synced: startIfAllowed()
        case .notPaired, .failed: break
        }
    }

    /// Uploads the buffer: on a new fix, on the wake drain and when the app opens.
    @discardableResult
    public func flush() async -> LocationUploadOutcome? {
        guard let identity = AgentIdentityStore.load() else { return nil }
        let batch = Array(LocationBuffer.load().prefix(LocationBuffer.capacity))
        guard !batch.isEmpty else { return nil }
        let outcome = await client.upload(identity, batch)
        switch outcome {
        case .stored, .rejected: LocationBuffer.remove(batch)
        case .consentWithdrawn: stopForConsent()
        case .unauthorized, .retryLater: break
        }
        return outcome
    }

    /// ADR-0034 A6 / ADR-0037: builds the capability report for an upload. The host app sets it at launch (it reads
    /// FamilyControls, the app groups and UIApplication); nil sends the grant alone, as before, and in the tests.
    public static var capabilityReport: (@MainActor (LocationGrant) -> CapabilityReport?)?

    /// At launch, on each app open, whenever the authorization changes, and after the app groups change.
    @discardableResult
    public func reportGrant() async -> Int? {
        guard let identity = AgentIdentityStore.load() else { return nil }
        return await client.reportGrant(identity, grant, capabilities: Self.capabilityReport?(grant))
    }

    /// `locate_now`: a fresh fix, else a cached one under five minutes old, uploaded before the ack.
    /// `ok` only after the server stored the point (#231's rule, `CommandAckPolicy.locateAck`); a failed
    /// upload is no ack, and the point stays buffered.
    public func locateNow(now: Date = Date()) async -> LocateAck? {
        switch grant {
        case .noAccess: return .failed(reason: LocateAck.permissionMissing)
        case .whileInUse: return .failed(reason: LocateAck.backgroundMissing)
        case .background: break
        }
        var fix = "fresh"
        var location = await source.requestOneFix(timeout: Self.fixTimeout)
        // `requestLocation()` can answer with a recent fix Core Location already held (Claude on #390): over a
        // minute old it is reported `cached`, so the parent's "fresh" means fresh; over five minutes it is no answer.
        if let got = location {
            let age = now.timeIntervalSince(got.timestamp)
            if age > Self.maxCachedAge {
                location = nil
            } else if age > Self.maxFreshAge {
                fix = "cached"
            }
        }
        if location == nil, let last = source.lastFix, now.timeIntervalSince(last.timestamp) < Self.maxCachedAge {
            location = last
            fix = "cached"
        }
        guard let location else { return .failed(reason: LocateAck.unavailable) }
        LocationBuffer.append([LocationPing(location)])
        let outcome = await flush()
        guard outcome == .stored else {
            Self.logger.error("locate_now point not stored (\(String(describing: outcome), privacy: .public)); no ack")
            return nil
        }
        return .ok(fix: fix)
    }
}

/// `CLLocationManager` behind [LocationSource]. Created on the main thread (by the main-actor controller),
/// so its delegate calls arrive there.
public final class CoreLocationSource: NSObject, LocationSource, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private let oneShot = OneShotFix()
    public var onLocations: (([CLLocation]) -> Void)?
    public var onAuthorizationChange: ((CLAuthorizationStatus) -> Void)?

    public override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.pausesLocationUpdatesAutomatically = true
    }

    public var authorizationStatus: CLAuthorizationStatus { manager.authorizationStatus }
    public var lastFix: CLLocation? { manager.location }

    public func startMonitoring() {
        guard CLLocationManager.significantLocationChangeMonitoringAvailable() else { return }
        manager.startMonitoringSignificantLocationChanges()
    }

    public func stopMonitoring() {
        manager.stopMonitoringSignificantLocationChanges()
    }

    public func requestWhenInUse() { manager.requestWhenInUseAuthorization() }
    public func requestAlways() { manager.requestAlwaysAuthorization() }

    @MainActor
    public func requestOneFix(timeout: TimeInterval) async -> CLLocation? {
        await oneShot.wait(timeout: timeout) { manager.requestLocation() }
    }

    public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // A fix a locate_now asked for answers it and is uploaded by it, not recorded a second time.
        if oneShot.isWaiting, let last = locations.last {
            oneShot.resolve(last)
            return
        }
        onLocations?(locations)
    }

    public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        oneShot.resolve(nil)
    }

    public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        onAuthorizationChange?(manager.authorizationStatus)
    }
}

/// The one outstanding `requestLocation()`, answered once: by a fix, a failure, or its own timeout. Each request
/// has a generation, so the timer of an earlier request cannot end a later one (Claude on #390: an app-open drain
/// overlapping a wake drain). A new request supersedes an older one still waiting, which answers nil and falls
/// back to the cached fix. Used on the main thread: the delegate calls arrive there, and the timer runs there.
final class OneShotFix {
    private var continuation: CheckedContinuation<CLLocation?, Never>?
    private var generation = 0

    var isWaiting: Bool { continuation != nil }

    /// On the main actor, so `start` (`requestLocation()`) runs on the thread the manager's delegate calls use.
    @MainActor
    func wait(timeout: TimeInterval, start: () -> Void) async -> CLLocation? {
        resolve(nil)
        generation += 1
        let mine = generation
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            start()
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard let self, self.generation == mine else { return }
                self.resolve(nil)
            }
        }
    }

    func resolve(_ location: CLLocation?) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: location)
    }
}
