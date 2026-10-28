import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// The identity returned once a pairing claim is approved (`POST /v1/devices/pair/claims/:id/poll`, 201)
/// (spec §14.2/§14.3). Persisted by `AgentIdentityStore`: the device token and
/// HMAC secret in the shared Keychain group, the ids in the shared app group.
/// `AlertReporter` and the Screen Time extensions read them from there.
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
    /// Another phone already holds a pending claim on this code (409); the parent makes a new one.
    case alreadyClaimed
    /// The parent tapped Deny (410).
    case denied
    /// The claim ended before the parent allowed it: the code expired, or the server no longer knows it.
    case expired
    /// Consent for the child is missing or was withdrawn (428).
    case consentRequired
}

/// What one answer of the pairing poll means (plan 2.7: the parent approves each new device).
public enum PairingPollStep: Equatable {
    case pending
    case approved(Data)
    case failed(PairingError)
}

/// Claims parent-issued 6-digit pairing codes against the OSRA API, waits for the
/// parent's Allow, and parses the approved poll's response into an [AgentIdentity].
///
/// The network call needs UIKit/Darwin networking; the URL normalizer and the
/// response parser are pure Foundation so the XCTest target exercises them on
/// macOS CI without entitlements.
public struct PairingClient {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// One poll every two seconds: the server's poll bucket is 60 a minute per address.
    public static let pollIntervalNanoseconds: UInt64 = 2_000_000_000
    /// A code lives 600 s, so a claim cannot outlive it; this bounds the wait if the server never says.
    public static let maxPolls = 330

    /// Claims [code] at [baseURL], waits for the parent to tap Allow, and returns the paired identity.
    ///
    /// Plan 2.7: the claim answers 202 with a claim id and a poll secret, and the device
    /// token arrives on `POST /v1/devices/pair/claims/:claimId/poll` once the parent has allowed this phone.
    /// Throws `PairingError` for every refusal (unknown code, code in use, Deny, expiry, consent) and parse
    /// failure; network errors on the claim propagate as thrown `Error` from URLSession.
    public func claim(
        baseURL: URL,
        code: String,
        deviceName: String?
    ) async throws -> AgentIdentity {
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
        if let refusal = Self.claimRefusal(status: http.statusCode) { throw refusal }
        guard let ticket = Self.parseClaimTicket(data) else { throw PairingError.unusableResponse }

        let pollURL = baseURL.appendingPathComponent("v1/devices/pair/claims/\(ticket.claimId)/poll")
        let pollBody = try JSONSerialization.data(withJSONObject: ["pollSecret": ticket.pollSecret])
        let session = self.session
        let approved = try await Self.awaitDecision(
            poll: {
                var poll = URLRequest(url: pollURL)
                poll.httpMethod = "POST"
                poll.setValue("application/json", forHTTPHeaderField: "Content-Type")
                poll.timeoutInterval = 30.0
                poll.httpBody = pollBody
                let (body, response) = try await session.data(for: poll)
                return ((response as? HTTPURLResponse)?.statusCode ?? 0, body)
            },
            sleep: { try await Task.sleep(nanoseconds: $0) }
        )
        guard let identity = Self.parseClaimResponse(approved, baseURL: baseURL) else {
            throw PairingError.unusableResponse
        }
        return identity
    }

    /// What the claim's status means: nil for 202 (waiting for the parent), the refusal otherwise.
    public static func claimRefusal(status: Int) -> PairingError? {
        switch status {
        case 202: return nil
        case 409: return .alreadyClaimed
        case 428: return .consentRequired
        default: return .httpError(status: status) // 404 = invalid_or_expired_code
        }
    }

    /// What one poll answer means. 201 is the only one that carries the device token.
    public static func pollStep(status: Int, body: Data) -> PairingPollStep {
        switch status {
        case 202: return .pending
        case 201: return .approved(body)
        case 410: return .failed(.denied)
        case 404: return .failed(.expired) // unknown, expired and a wrong secret are one answer on purpose
        case 428: return .failed(.consentRequired)
        default: return .failed(.httpError(status: status))
        }
    }

    /// Polls until the parent decides. A thrown network error is a missed poll, not an answer, so the loop
    /// carries on; it gives up with `.expired` after [maxPolls].
    public static func awaitDecision(
        poll: () async throws -> (Int, Data),
        sleep: (UInt64) async throws -> Void,
        maxPolls: Int = PairingClient.maxPolls
    ) async throws -> Data {
        for attempt in 0..<maxPolls {
            if attempt > 0 { try await sleep(pollIntervalNanoseconds) }
            guard let answer = try? await poll() else { continue }
            switch pollStep(status: answer.0, body: answer.1) {
            case .pending: continue
            case .approved(let data): return data
            case .failed(let error): throw error
            }
        }
        throw PairingError.expired
    }

    /// The claim's 202 body: what this phone polls with while the parent decides.
    public static func parseClaimTicket(_ data: Data) -> (claimId: String, pollSecret: String)? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let claimId = obj["claimId"] as? String, !claimId.isEmpty,
              let pollSecret = obj["pollSecret"] as? String, !pollSecret.isEmpty
        else { return nil }
        return (claimId, pollSecret)
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
        case PairingError.alreadyClaimed:
            return "This code is already being used by another phone. Ask your parent for a new code."
        case PairingError.denied:
            return "Your parent declined this phone. If that was a mistake, ask them for a new code."
        case PairingError.expired:
            return "The code expired before your parent allowed this phone. Ask them for a new code."
        case PairingError.consentRequired:
            return "Your parent needs to give consent in the OSRA app before this phone can be paired."
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
