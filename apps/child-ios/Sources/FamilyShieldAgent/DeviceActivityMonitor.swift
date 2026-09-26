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

    /// Fires a spec-conformant alert to POST /v1/alerts/internal; fire-and-forget with
    /// logged errors. The internal route requires childId/title/body and the
    /// X-FamilyShield-Signature header (spec §12.3).
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
        let payload: [String: Any] = [
            "childId": childId,
            "category": category,
            "severity": severity,
            "title": title,
            "body": body,
            "metadata": metadata,
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: payload) else { return }
        var request = URLRequest(url: apiBaseURL.appendingPathComponent("v1/alerts/internal"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData
        if let hmacSecret, let key = hmacSecret.data(using: .utf8) {
            let signature = HMAC<SHA256>.authenticationCode(for: bodyData, using: SymmetricKey(data: key))
            let hex = signature.map { String(format: "%02x", $0) }.joined()
            request.setValue(hex, forHTTPHeaderField: "X-FamilyShield-Signature")
        } else {
            AlertReporter.logger.warning("no HMAC secret configured; the API will reject this alert (401)")
        }
        URLSession.shared.dataTask(with: request) { _, response, error in
            if let error {
                AlertReporter.logger.error("alert '\(category)' failed: \(error.localizedDescription)")
            } else if let http = response as? HTTPURLResponse, http.statusCode >= 300 {
                AlertReporter.logger.error("alert '\(category)' rejected with HTTP \(http.statusCode)")
            }
        }.resume()
    }

    /// Reads the paired child id from the shared app group (written at pairing), if any.
    static func pairedChildId() -> String? {
        // NOTE: the app-group identifier is a placeholder until the Xcode project defines one.
        UserDefaults(suiteName: "group.dev.familyshield.agent")?.string(forKey: "agent.childId")
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
/// when a bedtime interval starts, restores the rule-blocked shield when it ends, and
/// reports screen-time threshold events to the backend.
///
/// NOTE: takes effect as the NSExtensionPrincipalClass of a Device Activity monitor
/// extension target. One `DeviceActivityName` per routine ID is registered by
/// `ScreenTimeController.scheduleBedtime(start:end:routineID:)`.
final class FamilyShieldDeviceActivityMonitor: DeviceActivityMonitor {

    private let store = ManagedSettingsStore()

    /// Reporter rebuilt per use so it picks up the `agent.apiBaseURL` value the pairing
    /// flow writes into the shared app group (nil until then — reports are skipped).
    private var reporter: AlertReporter { AlertReporter(hmacSecret: AlertReporter.pairedHmacSecret()) }

    /// Shields the union of the bedtime and rule-blocked app selections while the
    /// bedtime interval is active — applying only the bedtime tokens here would
    /// clobber apps that the parent's rules keep shielded.
    override func intervalDidStart(for activity: DeviceActivityName) {
        super.intervalDidStart(for: activity)
        let tokens = TokenResolver.applicationTokens(forBundleIdentifiers: Self.bedtimeBundleIdentifiers())
            .union(TokenResolver.applicationTokens(forBundleIdentifiers: Self.ruleBlockedBundleIdentifiers()))
        store.shield.applications = tokens.isEmpty ? nil : tokens
    }

    /// Restores the rule-blocked shield when the bedtime interval ends.
    override func intervalDidEnd(for activity: DeviceActivityName) {
        super.intervalDidEnd(for: activity)
        // NOTE: do NOT clear to nil here — that would un-shield apps blocked by the
        // parent's app rules while bedtime happens to be active. Re-apply the rule
        // selection instead (persisted by the main agent app in the shared app group).
        let tokens = TokenResolver.applicationTokens(forBundleIdentifiers: Self.ruleBlockedBundleIdentifiers())
        store.shield.applications = tokens.isEmpty ? nil : tokens
    }

    /// Reports a screen-time threshold breach with category "screen_time_exceeded".
    override func eventDidReachThreshold(_ event: DeviceActivityEvent.Name, activity: DeviceActivityName) {
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
        // NOTE: stub — production reads the synced RuleSet bedtime app selection,
        // persisted in the shared app group by the main agent app.
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
