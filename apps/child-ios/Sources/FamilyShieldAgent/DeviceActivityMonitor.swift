import Foundation
import os
import CryptoKit

/// Posts agent alerts to the FamilyShield backend API (spec §6.4 helper).
struct AlertReporter {

    private static let logger = Logger(subsystem: "dev.familyshield.agent", category: "Alerts")

    /// Base URL of the FamilyShield API (no trailing slash), read from the shared app
    /// group at init; nil until the pairing flow writes `agent.apiBaseURL`.
    var apiBaseURL: URL?

    /// Shared secret for X-FamilyShield-Signature; provisioned at device pairing and
    /// stored in the shared app group. Must match the server's INTERNAL_HMAC_SECRET.
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
        guard let apiBaseURL else {
            AlertReporter.logger.error("alert '\(category)' skipped: agent.apiBaseURL missing from shared app group (agent not paired)")
            return
        }
        guard let childId, !childId.isEmpty else {
            AlertReporter.logger.error("alert '\(category)' skipped: childId unknown (agent not paired)")
            return
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
        guard let bodyData = try? JSONSerialization.data(withJSONObject: payload) else { return }
        var request = URLRequest(url: apiBaseURL.appendingPathComponent("v1/alerts/internal"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData
        request.timeoutInterval = 15.0
        if let hmacSecret {
            // v2 internal signing (ADR-0014): timestamp + nonce + HMAC over "ts.nonce.body".
            let headers = InternalSigner.sign(secret: hmacSecret, body: bodyData)
            for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        } else {
            AlertReporter.logger.warning("no HMAC secret configured; the API will reject this alert (401)")
        }

        Self.sendWithRetry(request: request, category: category, attemptsLeft: 3)
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

    /// Reads the pairing HMAC secret from the shared app group, if any.
    static func pairedHmacSecret() -> String? {
        UserDefaults(suiteName: "group.dev.familyshield.agent")?.string(forKey: "agent.hmacSecret")
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
public final class FamilyShieldDeviceActivityMonitor: DeviceActivityMonitor {

    /// Reporter rebuilt per use so it picks up the `agent.apiBaseURL` value the pairing
    /// flow writes into the shared app group (nil until then — reports are skipped).
    private var reporter: AlertReporter { AlertReporter(hmacSecret: AlertReporter.pairedHmacSecret()) }

    /// Shields the bedtime apps in a dedicated named store for this routine (IOS-05).
    /// Using a routine-specific named store ensures overlapping routines do not clobber
    /// each other, and rule-blocked apps managed in `parentRules` store remain shielded.
    public override func intervalDidStart(for activity: DeviceActivityName) {
        super.intervalDidStart(for: activity)
        let routineStore = ManagedSettingsStore(named: ManagedSettingsStore.Name(activity.rawValue))
        let tokens = TokenResolver.applicationTokens(forBundleIdentifiers: Self.bedtimeBundleIdentifiers())
        routineStore.shield.applications = tokens.isEmpty ? nil : tokens
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

    /// Bundle identifiers to shield during bedtime, read from the shared app-group store.
    private static func bedtimeBundleIdentifiers() -> [String] {
        UserDefaults(suiteName: "group.dev.familyshield.agent")?
            .stringArray(forKey: "bedtime.blockedBundleIdentifiers") ?? []
    }

    /// Bundle identifiers blocked by the parent's app rules, read from the shared app-group store.
    private static func ruleBlockedBundleIdentifiers() -> [String] {
        UserDefaults(suiteName: "group.dev.familyshield.agent")?
            .stringArray(forKey: "apps.blockedBundleIdentifiers") ?? []
    }
}
#endif
