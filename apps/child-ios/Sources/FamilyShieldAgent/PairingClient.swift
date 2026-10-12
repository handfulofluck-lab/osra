import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// The identity returned by a successful `POST /v1/devices/pair/claim`
/// (spec §14.2/§14.3). Persisted in the shared app group by
/// `AgentIdentityStore`; `AlertReporter` and the Screen Time extensions read
/// `childId` / `hmacSecret` / `apiBaseURL` from the same store.
public struct AgentIdentity: Equatable {
    /// Normalized server base URL (no trailing slash).
    public var apiBaseURL: URL
    /// Device JWT (Bearer) minted by the claim endpoint.
    public var deviceToken: String
    /// Server-side device row id.
    public var deviceId: String
    /// The child this device is bound to.
    public var childId: String
    /// The child's family (returned by the claim endpoint).
    public var familyId: String
    /// Per-deployment HMAC secret for `X-FamilyShield-Signature` internal calls;
    /// nil when the server did not provision one (alerts then fail closed with a 401).
    public var hmacSecret: String?

    public init(apiBaseURL: URL, deviceToken: String, deviceId: String, childId: String, familyId: String, hmacSecret: String?) {
        self.apiBaseURL = apiBaseURL
        self.deviceToken = deviceToken
        self.deviceId = deviceId
        self.childId = childId
        self.familyId = familyId
        self.hmacSecret = hmacSecret
    }
}

/// Pairing failures surfaced to the UI.
public enum PairingError: Error, Equatable {
    /// The entered server URL could not be normalized into http(s)://host[:port].
    case invalidServerURL
    /// The code is not exactly 6 digits.
    case invalidCode
    /// The server rejected the claim (404 = invalid/expired code, 4xx/5xx otherwise).
    case httpError(status: Int)
    /// The response was not the expected claim payload.
    case unusableResponse
}

/// Claims parent-issued 6-digit pairing codes against the OSRA API and parses
/// the claim response into an [AgentIdentity].
///
/// The network call needs UIKit/Darwin networking; the URL normalizer and the
/// response parser are pure Foundation so the XCTest target exercises them on
/// macOS CI without entitlements.
public struct PairingClient {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// Claims [code] at [baseURL] and returns the paired identity.
    /// Throws `PairingError` for validation and HTTP/parse failures; network
    /// errors propagate as thrown `Error` from URLSession.
    public func claim(baseURL: URL, code: String, deviceName: String?) async throws -> AgentIdentity {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/devices/pair/claim"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30.0 // 30s timeout so pairing never hangs indefinitely (IOS-07)
        var payload: [String: Any] = [
            "code": code,
            "platform": "ios",
            "model": Self.deviceModel(),
            "osVersion": Self.osVersion(),
        ]
        if let deviceName, !deviceName.trimmingCharacters(in: .whitespaces).isEmpty {
            payload["deviceName"] = deviceName.trimmingCharacters(in: .whitespaces)
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw PairingError.unusableResponse }
        // The API returns 201 on success and 404 for invalid_or_expired_code.
        guard http.statusCode == 201 else { throw PairingError.httpError(status: http.statusCode) }
        guard let identity = Self.parseClaimResponse(data, baseURL: baseURL) else {
            throw PairingError.unusableResponse
        }
        return identity
    }

    /// Normalizes a user-entered server URL: trims whitespace, prepends
    /// `http://` when the scheme is missing (testers type `192.168.1.5:3000`)
    /// and strips trailing slashes. Returns nil for empty or non-http(s) input.
    public static func normalizeServerURL(_ raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        if s.isEmpty { return nil }
        if !s.contains("://") { s = "http://" + s }
        guard let url = URL(string: s),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty
        else { return nil }
        return url
    }

    /// Pure claim-response parser (testable on macOS CI). Tolerates `device`
    /// as an object (the API shape `{ device: { id, ... } }`) or a bare string,
    /// mirroring the desktop agent's ClaimResponse. `hmacSecret: null`/missing
    /// or empty yields a nil secret so callers fail closed at the API.
    public static func parseClaimResponse(_ data: Data, baseURL: URL) -> AgentIdentity? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = obj["token"] as? String, !token.isEmpty,
              let childId = obj["childId"] as? String, !childId.isEmpty
        else { return nil }

        var deviceId = ""
        if let device = obj["device"] as? [String: Any], let id = device["id"] as? String {
            deviceId = id
        } else if let id = obj["device"] as? String {
            deviceId = id
        }

        let familyId = (obj["familyId"] as? String) ?? ""
        let rawHmac = obj["hmacSecret"] as? String
        let hmac = (rawHmac?.isEmpty == false) ? rawHmac : nil

        return AgentIdentity(
            apiBaseURL: baseURL,
            deviceToken: token,
            deviceId: deviceId,
            childId: childId,
            familyId: familyId,
            hmacSecret: hmac
        )
    }

    /// Human-readable error text for the pairing form.
    public static func message(for error: Error) -> String {
        switch error {
        case PairingError.invalidServerURL:
            return "Enter a valid server address, e.g. 192.168.1.5:3000"
        case PairingError.invalidCode:
            return "Enter the 6-digit pairing code."
        case PairingError.httpError(let status) where status == 404:
            return "Invalid or expired code. Ask your parent for a new one."
        case PairingError.httpError(let status):
            return "The server rejected the request (HTTP \(status))."
        case PairingError.unusableResponse:
            return "Unexpected server response — check the server address."
        default:
            return "Cannot reach the server — check the address and network."
        }
    }

    private static func deviceModel() -> String {
        #if canImport(UIKit)
        return UIDevice.current.model // "iPhone" / "iPad"
        #else
        return "iOS device"
        #endif
    }

    private static func osVersion() -> String {
        #if canImport(UIKit)
        return UIDevice.current.systemVersion
        #else
        return ProcessInfo.processInfo.operatingSystemVersionString
        #endif
    }
}
