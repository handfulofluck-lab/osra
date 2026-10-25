import Foundation
import os
import CryptoKit

/// Posts agent alerts to the FamilyShield backend API (spec §6.4 helper).
struct AlertReporter {

    private static let logger = Logger(subsystem: "dev.familyshield.agent", category: "Alerts")

    /// Base URL of the FamilyShield API (no trailing slash), read from the shared app
    /// group at init; nil until the pairing flow writes `agent.apiBaseURL`.
    var apiBaseURL: URL?

    /// Per-device secret for X-FamilyShield-Signature; provisioned at device pairing and
    /// stored in the shared Keychain group (`AgentIdentityStore`).
    var hmacSecret: String?

    /// Creates a reporter pointing at the paired API base URL, if configured.
    init(apiBaseURL: URL? = AlertReporter.pairedApiBaseURL(), hmacSecret: String? = nil) {
        self.apiBaseURL = apiBaseURL
        self.hmacSecret = hmacSecret
    }

    /// Fires a spec-conformant alert to POST /v1/alerts/internal with retry and backoff (IOS-08).
    /// Includes deviceId in the payload so the server resolves the per-device HMAC secret (IOS-01).
    func report(
        category: String,
        severity: String = "warning",
        title: String,
        body: String,
        childId: String?,
        metadata: [String: Any] = [:]
    ) {
        guard let request = makeRequest(category: category, severity: severity, title: title, body: body,
                                        childId: childId, metadata: metadata)
        else { return }
        Self.sendWithRetry(request: request, category: category, attemptsLeft: 3)
    }

    /// Sends one alert and returns the server's status and body, once, without retrying. The same request
    /// as `report` (built by `makeRequest`), for callers that need the answer: the live API tests (5.5 A2).
    func send(
        category: String,
        severity: String = "warning",
        title: String,
        body: String,
        childId: String?,
        metadata: [String: Any] = [:]
    ) async throws -> (status: Int, body: Data) {
        guard let request = makeRequest(category: category, severity: severity, title: title, body: body,
                                        childId: childId, metadata: metadata)
        else { throw URLError(.cancelled) }
        return try await Self.send(request)
    }

    /// Sends a prepared request once and returns the status and body.
    static func send(_ request: URLRequest) async throws -> (status: Int, body: Data) {
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    /// The signed `POST /v1/alerts/internal` request, or nil when the agent is not paired. `signedAt`
    /// (Unix seconds) overrides the signing clock; only the live tests set it, to send a stale request.
    func makeRequest(
        category: String,
        severity: String = "warning",
        title: String,
        body: String,
        childId: String?,
        metadata: [String: Any] = [:],
        signedAt: Int? = nil
    ) -> URLRequest? {
        guard let apiBaseURL else {
            AlertReporter.logger.error("alert '\(category)' skipped: agent.apiBaseURL missing from shared app group (agent not paired)")
            return nil
        }
        guard let childId, !childId.isEmpty else {
            AlertReporter.logger.error("alert '\(category)' skipped: childId unknown (agent not paired)")
            return nil
        }
        var payload: [String: Any] = [
            "childId": childId,
            "category": category,
            "severity": severity,
            "title": title,
            "body": body,
            "metadata": metadata,
        ]
        if let deviceId = AlertReporter.pairedDeviceId() {
            payload["deviceId"] = deviceId
        }
        guard let bodyData = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        var request = URLRequest(url: apiBaseURL.appendingPathComponent("v1/alerts/internal"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData
        request.timeoutInterval = 15.0
        if let hmacSecret {
            // v2 internal signing (ADR-0014): timestamp + nonce + HMAC over "ts.nonce.body".
            let headers = InternalSigner.sign(secret: hmacSecret, body: bodyData, unixSeconds: signedAt)
            for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        } else {
            AlertReporter.logger.warning("no HMAC secret configured; the API will reject this alert (401)")
        }
        return request
    }

    private static func sendWithRetry(request: URLRequest, category: String, attemptsLeft: Int) {
        URLSession.shared.dataTask(with: request) { _, response, error in
            if let error {
                AlertReporter.logger.error("alert '\(category)' failed: \(error.localizedDescription)")
                if attemptsLeft > 1 {
                    DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) {
                        sendWithRetry(request: request, category: category, attemptsLeft: attemptsLeft - 1)
                    }
                }
            } else if let http = response as? HTTPURLResponse, http.statusCode >= 300 {
                AlertReporter.logger.error("alert '\(category)' rejected with HTTP \(http.statusCode)")
                if http.statusCode >= 500 && attemptsLeft > 1 {
                    DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) {
                        sendWithRetry(request: request, category: category, attemptsLeft: attemptsLeft - 1)
                    }
                }
            } else {
                AlertReporter.logger.info("alert '\(category)' delivered successfully")
            }
        }.resume()
    }

    /// Reads the paired child id from the shared app group (written at pairing), if any.
    static func pairedChildId() -> String? {
        UserDefaults(suiteName: "group.dev.familyshield.agent")?.string(forKey: "agent.childId")
    }

    /// Reads the paired device id from the shared app group (written at pairing), if any (IOS-01).
    static func pairedDeviceId() -> String? {
        UserDefaults(suiteName: "group.dev.familyshield.agent")?.string(forKey: "agent.deviceId")
    }

    /// Reads the pairing API base URL from the shared app group, if any.
    static func pairedApiBaseURL() -> URL? {
        guard let raw = UserDefaults(suiteName: "group.dev.familyshield.agent")?
            .string(forKey: "agent.apiBaseURL"), !raw.isEmpty
        else { return nil }
        return URL(string: raw)
    }

    /// Reads the pairing HMAC secret from the shared Keychain group (5.5 PR B), if any.
    static func pairedHmacSecret() -> String? {
        AgentIdentityStore.hmacSecret()
    }
}

#if canImport(DeviceActivity) && canImport(ManagedSettings)
import DeviceActivity
import ManagedSettings

/// Device-activity monitor for FamilyShield (spec §6.4): applies the bedtime shield
/// when a bedtime interval starts in a routine-specific named store, and clears only that
/// routine store when it ends without unshielding parent rules (IOS-05).
///
/// The monitor extension target (`Extensions/Monitor`) names this class as its
/// NSExtensionPrincipalClass. `@objc(...)` gives it that unqualified runtime name, and it is
/// public so the extension can reference it, which keeps the static linker from dropping it.
@objc(FamilyShieldDeviceActivityMonitor)
public final class FamilyShieldDeviceActivityMonitor: DeviceActivityMonitor {

    /// Reporter rebuilt per use so it picks up the `agent.apiBaseURL` value the pairing
    /// flow writes into the shared app group (nil until then — reports are skipped).
    private var reporter: AlertReporter { AlertReporter(hmacSecret: AlertReporter.pairedHmacSecret()) }

    /// Applies `ShieldPolicy` in a named store per activity (IOS-05), so overlapping intervals don't clobber
    /// each other and the all-day `parentRules` shields stay. Bedtime, and a routine with `allowedApps`,
    /// shield everything except the allowed apps; a routine with only `blockedApps` shields those; a routine
    /// on a day it doesn't run shields nothing (5.5 PR C).
    public override func intervalDidStart(for activity: DeviceActivityName) {
        super.intervalDidStart(for: activity)
        let store = ManagedSettingsStore(named: ManagedSettingsStore.Name(activity.rawValue))
        // The day the interval starts on decides, so an overnight routine is judged by its first day.
        let weekday = Calendar.current.component(.weekday, from: Date())
        switch ShieldPolicy.current(activity: activity.rawValue, weekday: weekday) {
        case .allExcept(let allowed):
            // Everything but the allowed apps. A bundle id with no token stays shielded: fails closed.
            let exceptions = Set(allowed.compactMap { Application(bundleIdentifier: $0).token })
            store.shield.applicationCategories = .all(except: exceptions)
        case .only(let blocked):
            let tokens = TokenResolver.applicationTokens(forBundleIdentifiers: blocked)
            store.shield.applications = tokens.isEmpty ? nil : tokens
        case .none:
            break
        }
    }

    /// Clears only the routine-specific named store when bedtime interval ends (IOS-05).
    /// Does NOT clear `parentRules` or other overlapping routines.
    public override func intervalDidEnd(for activity: DeviceActivityName) {
        super.intervalDidEnd(for: activity)
        let routineStore = ManagedSettingsStore(named: ManagedSettingsStore.Name(activity.rawValue))
        routineStore.clearAllSettings()
    }

    /// Reports a screen-time threshold breach with category "screen_time_exceeded".
    public override func eventDidReachThreshold(_ event: DeviceActivityEvent.Name, activity: DeviceActivityName) {
        super.eventDidReachThreshold(event, activity: activity)
        reporter.report(
            category: "screen_time_exceeded",
            severity: "warning",
            title: "Screen time limit reached",
            body: "Screen time threshold reached (event \(event.rawValue), activity \(activity.rawValue)).",
            childId: AlertReporter.pairedChildId(),
            metadata: ["event": event.rawValue, "activity": activity.rawValue]
        )
    }

    /// Bundle identifiers blocked by the parent's app rules, read from the shared app-group store.
    private static func ruleBlockedBundleIdentifiers() -> [String] {
        UserDefaults(suiteName: "group.dev.familyshield.agent")?
            .stringArray(forKey: "apps.blockedBundleIdentifiers") ?? []
    }
}
#endif
