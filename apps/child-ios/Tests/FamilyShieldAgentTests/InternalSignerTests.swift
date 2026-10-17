import XCTest
@testable import FamilyShieldAgent

/// v2 internal signing (ADR-0014) — pinned to the same reference vector as the API, Android and Windows tests.
final class InternalSignerTests: XCTestCase {
    func testSigningBytesIsTimestampDotNonceDotBody() {
        let bytes = InternalSigner.signingBytes(timestamp: "1800000000", nonce: "0123456789abcdef0123456789abcdef", body: Data("{\"a\":1}".utf8))
        XCTAssertEqual(String(decoding: bytes, as: UTF8.self), "1800000000.0123456789abcdef0123456789abcdef.{\"a\":1}")
    }

    func testSignatureMatchesServerReferenceVector() {
        let body = Data("{\"childId\":\"child-1\",\"deviceId\":\"dev-1\",\"title\":\"x\"}".utf8)
        let headers = InternalSigner.sign(secret: "device-secret-1", body: body, unixSeconds: 1_800_000_000, nonce: "nonce-0123456789abcdef")
        XCTAssertEqual(headers[InternalSigner.signatureHeader], "ce725cf93f36fb43a586bcae590b3faab54afa4976347b859c9ca9259c220508")
        XCTAssertEqual(headers[InternalSigner.timestampHeader], "1800000000")
        XCTAssertEqual(headers[InternalSigner.nonceHeader], "nonce-0123456789abcdef")
    }

    func testNonceIs32LowercaseHexAndUnique() {
        let a = InternalSigner.newNonce()
        let b = InternalSigner.newNonce()
        XCTAssertEqual(a.count, 32)
        XCTAssertNotNil(a.range(of: "^[0-9a-f]+$", options: .regularExpression))
        XCTAssertNotEqual(a, b)
    }
}
