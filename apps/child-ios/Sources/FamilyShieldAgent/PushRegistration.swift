import Foundation
import os

/// Uploads the APNs device token so the server can wake this phone (5.5 PR D, #372):
/// `POST /v1/devices/:id/push-token` with the device token (device-only since #319).
///
/// Uploaded when the token or the paired device changes, and not otherwise: iOS hands the app its token on
/// every launch, and a token is not a reason for a request when the server already holds it.
public enum PushTokenRegistrar {
    private static let logger = Logger(subsystem: "dev.familyshield.agent", category: "Push")

    enum Keys {
        static let uploadedToken = "push.uploadedToken"
        static let uploadedForDevice = "push.uploadedForDevice"
    }

    /// The APNs token bytes as the lowercase hex the provider API takes.
    public static func hex(_ token: Data) -> String {
        token.map { String(format: "%02x", $0) }.joined()
    }

    public enum Outcome: Equatable {
        case notPaired
        case alreadyUploaded
        case uploaded
        case failed(Int)
    }

    @discardableResult
    public static func register(tokenHex: String, session: URLSession = .shared) async -> Outcome {
        guard let identity = AgentIdentityStore.load(), !identity.deviceId.isEmpty else { return .notPaired }
        let defaults = UserDefaults(suiteName: AgentIdentityStore.suiteName)
        if defaults?.string(forKey: Keys.uploadedToken) == tokenHex,
           defaults?.string(forKey: Keys.uploadedForDevice) == identity.deviceId {
            return .alreadyUploaded
        }
        var request = URLRequest(url: identity.apiBaseURL.appendingPathComponent("v1/devices")
            .appendingPathComponent(identity.deviceId).appendingPathComponent("push-token"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(identity.deviceToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["token": tokenHex])
        request.timeoutInterval = 30
        let status: Int
        do {
            let (_, response) = try await session.data(for: request)
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
        } catch {
            logger.error("push token upload failed: \(error.localizedDescription, privacy: .public)")
            return .failed(0)
        }
        guard status == 204 else {
            logger.error("push token upload answered \(status)")
            return .failed(status)
        }
        defaults?.set(tokenHex, forKey: Keys.uploadedToken)
        defaults?.set(identity.deviceId, forKey: Keys.uploadedForDevice)
        return .uploaded
    }

    /// Forgets what was uploaded (unpairing), so the next pairing uploads again.
    public static func forget() {
        let defaults = UserDefaults(suiteName: AgentIdentityStore.suiteName)
        defaults?.removeObject(forKey: Keys.uploadedToken)
        defaults?.removeObject(forKey: Keys.uploadedForDevice)
    }
}
