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
        /// Nothing was uploaded for this pairing yet, so there is nothing to send again (#383).
        case nothingToResend
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
        return await upload(tokenHex, for: identity, session: session)
    }

    /// The poll answered `X-Push-Token: none` (#383): the server cleared this device's token, most likely after
    /// a wake it read as a dead token. Sends the token uploaded for this pairing again, past the
    /// "already uploaded" check; a token iOS has since rotated arrives through [register] as usual.
    @discardableResult
    public static func resendAfterServerCleared(session: URLSession = .shared) async -> Outcome {
        guard let identity = AgentIdentityStore.load(), !identity.deviceId.isEmpty else { return .notPaired }
        let defaults = UserDefaults(suiteName: AgentIdentityStore.suiteName)
        guard let token = defaults?.string(forKey: Keys.uploadedToken), !token.isEmpty,
              defaults?.string(forKey: Keys.uploadedForDevice) == identity.deviceId else {
            return .nothingToResend
        }
        return await upload(token, for: identity, session: session)
    }

    private static func upload(_ tokenHex: String, for identity: AgentIdentity, session: URLSession) async -> Outcome {
        let defaults = UserDefaults(suiteName: AgentIdentityStore.suiteName)
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
