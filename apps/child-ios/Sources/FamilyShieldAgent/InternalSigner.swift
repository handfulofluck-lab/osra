import CryptoKit
import Foundation

/// v2 internal request signing (ADR-0014): the three headers the API verifies on every `/internal`
/// call. The signature is HMAC-SHA256 over `"<timestamp>.<nonce>."` followed by the exact body bytes;
/// the server rejects a timestamp more than 5 minutes off its clock and any nonce it has already seen
/// for this device, so a captured request cannot be replayed. Pinned to the same reference vector as
/// the API, Android and Windows tests.
public enum InternalSigner {
    public static let signatureHeader = "X-FamilyShield-Signature"
    public static let timestampHeader = "X-FamilyShield-Timestamp"
    public static let nonceHeader = "X-FamilyShield-Nonce"

    /// The v2 signing string: timestamp, nonce and body, dot-joined, byte for byte.
    public static func signingBytes(timestamp: String, nonce: String, body: Data) -> Data {
        var data = Data("\(timestamp).\(nonce).".utf8)
        data.append(body)
        return data
    }

    /// Lowercase hex HMAC-SHA256 of `data` under `secret`.
    public static func hmacHex(secret: String, data: Data) -> String {
        let key = SymmetricKey(data: Data(secret.utf8))
        return HMAC<SHA256>.authenticationCode(for: data, using: key).map { String(format: "%02x", $0) }.joined()
    }

    /// 16 random bytes as 32 lowercase hex characters.
    public static func newNonce() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// The three v2 headers for `body`.
    public static func sign(secret: String, body: Data, unixSeconds: Int? = nil, nonce: String? = nil) -> [String: String] {
        let ts = String(unixSeconds ?? Int(Date().timeIntervalSince1970))
        let n = nonce ?? newNonce()
        return [
            signatureHeader: hmacHex(secret: secret, data: signingBytes(timestamp: ts, nonce: n, body: body)),
            timestampHeader: ts,
            nonceHeader: n,
        ]
    }
}
