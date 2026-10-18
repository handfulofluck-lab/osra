/// Stable payload carried by the parent app's pairing QR code.
///
/// Format (version 1, documented in `docs/SPEC.md` §14.4):
///
/// ```text
/// osra://pair?v=1&code=482916&host=http%3A%2F%2F192.168.1.5%3A3000
/// ```
///
/// * `v` is the payload version; a decoder must refuse versions it does not know.
/// * `code` is the same six-digit code `POST /v1/devices/pair` returns.
/// * `host` is the parent app's API base URL (scheme + host + optional port and
///   path), percent-encoded as a query value. The scheme and port matter: the
///   child device has to reach the same server the parent is signed in to.
///
/// The payload is intentionally not a bare code so a scanner can also learn
/// which server to call. This file is pure Dart (no Flutter imports) so both the
/// parent QR screen and the future child scanner can share it.
library;

/// The URI scheme and authority of a version-1 pairing payload.
const String kPairQrScheme = 'osra';
const String kPairQrAuthority = 'pair';

/// Current payload version. Bump only with a decoder change.
const int kPairQrVersion = 1;

/// The server's pair-code TTL: `PAIR_TTL_SECONDS = 600` in
/// `services/api/src/routes/devices.ts`. The screen counts down to the
/// server-supplied `expiresAt`; this constant is the documented fallback.
const Duration kPairCodeTtl = Duration(seconds: 600);

/// Six-digit code, exactly as the API mints and `/pair/claim` accepts it.
final RegExp _codePattern = RegExp(r'^\d{6}$');

/// One decoded pairing QR payload.
class PairQrPayload {
  const PairQrPayload({required this.code, required this.apiBaseUrl});

  final String code;

  /// API base URL without a trailing slash, e.g. `http://192.168.1.5:3000`.
  final String apiBaseUrl;

  /// The stable, scannable string for [code] and [apiBaseUrl].
  ///
  /// Throws [FormatException] when either field is not encodable as version 1:
  /// the code must be six digits and the base URL must be an absolute
  /// `http(s)` URL with a host.
  String encode() {
    if (!_codePattern.hasMatch(code)) {
      throw const FormatException('pairing code must be six digits');
    }
    if (!_isApiBaseUrl(apiBaseUrl)) {
      throw FormatException('pairing host must be an http(s) URL: $apiBaseUrl');
    }
    // A literal map keeps the parameter order stable (v, code, host) across
    // Dart versions, so the encoded string is reproducible and test-pinned.
    final uri = Uri(
      scheme: kPairQrScheme,
      host: kPairQrAuthority,
      queryParameters: <String, String>{
        'v': '$kPairQrVersion',
        'code': code,
        'host': apiBaseUrl,
      },
    );
    return uri.toString();
  }

  /// Decodes [raw], throwing [FormatException] for anything that is not a
  /// complete version-1 payload.
  static PairQrPayload decode(String raw) {
    final uri = Uri.tryParse(raw);
    if (uri == null ||
        uri.scheme != kPairQrScheme ||
        uri.host != kPairQrAuthority ||
        uri.path.isNotEmpty && uri.path != '/') {
      throw FormatException('not an OSRA pairing payload: $raw');
    }
    final version = uri.queryParameters['v'];
    if (version != '$kPairQrVersion') {
      throw FormatException(
          'unsupported pairing payload version: ${version ?? 'missing'}');
    }
    final code = uri.queryParameters['code'];
    if (code == null || !_codePattern.hasMatch(code)) {
      throw const FormatException('pairing payload has no six-digit code');
    }
    final host = uri.queryParameters['host'];
    if (host == null || !_isApiBaseUrl(host)) {
      throw const FormatException('pairing payload has no valid http(s) host');
    }
    return PairQrPayload(code: code, apiBaseUrl: host);
  }

  /// [decode] without the exception, for scanners that show "not an OSRA code".
  static PairQrPayload? tryDecode(String raw) {
    try {
      return decode(raw);
    } on FormatException {
      return null;
    }
  }

  static bool _isApiBaseUrl(String value) {
    final uri = Uri.tryParse(value);
    return uri != null &&
        (uri.scheme == 'http' || uri.scheme == 'https') &&
        uri.host.isNotEmpty &&
        uri.query.isEmpty &&
        uri.fragment.isEmpty;
  }

  @override
  bool operator ==(Object other) =>
      other is PairQrPayload &&
      other.code == code &&
      other.apiBaseUrl == apiBaseUrl;

  @override
  int get hashCode => Object.hash(code, apiBaseUrl);

  @override
  String toString() => 'PairQrPayload(code: $code, apiBaseUrl: $apiBaseUrl)';
}
