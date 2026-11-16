import Foundation
import FamilyShieldAgent

/// Proves that the HMAC secret this Mac holds is the one the server holds for it, before anything says "paired"
/// (#775: "a wrong HMAC key must be refused by the server and the daemon must not report paired").
///
/// The proof is one request signed with the shared `InternalSigner` (ADR-0014) and nothing else: no device
/// token. It goes to `POST /v1/location/ping` with **no pings in it**, because that route is the one that
/// accepts a device's signature on its own, and it checks the signature before it reads the body:
///
/// - `401` with a reason: the signature was refused. A wrong key is `invalid_signature`.
/// - `400`: the signature was accepted, and the empty batch was then refused. Nothing is stored; the Mac sends
///   no location, now or later in this step.
///
/// The request spends one nonce and writes nothing. A signed no-op route would say the same thing more
/// plainly; that is a server change and is proposed as a follow-up, not made here.
public enum SecretProof {
    public enum Outcome: Equatable {
        /// The server accepted the signature.
        case accepted
        /// The server refused the signature, or this Mac holds no secret; the word is the server's reason.
        case refused(String)
        /// The server refused the timestamp: this Mac's clock is more than five minutes off.
        case clockSkew
        /// No verdict: offline, a server fault, or an answer this client does not know. The status is 0 offline.
        case inconclusive(Int)
    }

    /// `{"deviceId": "...", "pings": []}`: names the device, so only that device's own secret can sign it.
    public static func body(deviceId: String) -> Data {
        let object: [String: Any] = ["deviceId": deviceId, "pings": [Any]()]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }

    /// The signed request. It carries no `Authorization` header on purpose: with a device token the route would
    /// never look at the signature, and the proof would prove nothing.
    public static func request(baseURL: URL, deviceId: String, secret: String,
                               unixSeconds: Int? = nil, nonce: String? = nil) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/location/ping"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 20
        let payload = Self.body(deviceId: deviceId)
        request.httpBody = payload
        for (header, value) in InternalSigner.sign(secret: secret, body: payload, unixSeconds: unixSeconds, nonce: nonce) {
            request.setValue(value, forHTTPHeaderField: header)
        }
        return request
    }

    /// What the server's answer means. Only a 400 is "accepted": it is the one answer that can only come from
    /// behind the signature check.
    public static func outcome(status: Int, body: Data?) -> Outcome {
        switch status {
        case 400:
            return .accepted
        case 401:
            let object = body.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
            let reason = object?["reason"] as? String
            switch reason {
            case "stale_timestamp": return .clockSkew
            case "nonce_store_unavailable": return .inconclusive(status)
            default:
                if let reason, knownReasons.contains(reason) { return .refused(reason) }
                return .refused("unauthorized")
            }
        default:
            return .inconclusive(status)
        }
    }

    /// The server's refusal words this client repeats in its own log; anything else is logged as "unauthorized",
    /// so a server answer can never put arbitrary text there.
    static let knownReasons: Set<String> = ["invalid_signature", "device_has_no_secret", "missing_signature",
                                            "missing_nonce", "replay", "legacy_signature_disabled"]

    /// The test bed's planted fault, for #775's device row "a wrong HMAC key must be refused by the server". It is
    /// compiled in only by `scripts/install-dev.sh --plant-wrong-hmac-key` (`-DOSRA_PLANT_WRONG_HMAC_KEY`); no
    /// other build, and nothing at run time, can turn it on. A build that carries it says so in `version` and at
    /// every start, and all it can do is make this Mac's own signature wrong, so pairing fails closed.
    public static var plantedWrongKey: Bool {
        #if OSRA_PLANT_WRONG_HMAC_KEY
        return true
        #else
        return false
        #endif
    }

    /// The key the proof signs with: the device's secret, or a wrong one in a planted build.
    static func signingSecret(_ secret: String, planted: Bool = plantedWrongKey) -> String {
        planted ? secret + ".planted-wrong-key" : secret
    }

    public static func check(_ identity: AgentIdentity, session: URLSession = .shared) async -> Outcome {
        guard let secret = identity.hmacSecret, !secret.isEmpty, !identity.deviceId.isEmpty else {
            return .refused("device_has_no_secret")
        }
        let signed = Self.request(baseURL: identity.apiBaseURL, deviceId: identity.deviceId,
                                  secret: signingSecret(secret))
        do {
            let (data, response) = try await session.data(for: signed)
            return outcome(status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: data)
        } catch {
            return .inconclusive(0)
        }
    }
}
