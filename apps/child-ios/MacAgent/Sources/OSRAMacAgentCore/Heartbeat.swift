import Foundation
import FamilyShieldAgent

/// The heartbeat: `POST /v1/devices/:id/telemetry` with the device token, the endpoint every agent uses. The
/// server answers by marking the device online and refreshing "last seen", which is what the parent app shows,
/// and a Mac that stops sending raises the missed-heartbeat tamper alert (ADR-0027).
///
/// The body is the capability report and nothing else. It carries no `appliedRulesVersion`: the daemon stores
/// the rules and enforces none of them yet, and that field means "saved and applied" (#475). The parent's "not
/// picked up yet" line therefore stays, truthfully, until the steps that enforce.
public struct HeartbeatClient {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public static func body(report: MacCapabilityReport) -> [String: Any] {
        ["capabilities": report.json]
    }

    public static func request(_ identity: AgentIdentity, report: MacCapabilityReport) -> URLRequest {
        var request = URLRequest(url: identity.apiBaseURL.appendingPathComponent("v1/devices")
            .appendingPathComponent(identity.deviceId).appendingPathComponent("telemetry"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(identity.deviceToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(report.clientHeader, forHTTPHeaderField: "X-OSRA-Client")
        request.timeoutInterval = 20
        request.httpBody = try? JSONSerialization.data(withJSONObject: body(report: report))
        return request
    }

    /// Sends one heartbeat and returns the HTTP status (0 offline). A `device_revoked` answer unpairs this Mac
    /// through the shared code (#690), exactly as on the iPhone.
    @discardableResult
    public func send(_ identity: AgentIdentity, report: MacCapabilityReport = MacCapabilityReport()) async -> Int {
        do {
            let (data, response) = try await session.data(for: Self.request(identity, report: report))
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            DeviceRevocation.handle(status: status, body: data)
            return status
        } catch {
            return 0
        }
    }
}
