/// Issue #742 — a mutation from the parent app must be authorised by the phone's owner before it is sent.
///
/// Karim's decision (13 Nov, card log in #617): before any rule change, unlinking a device or pausing, the
/// app asks for the phone's own biometric or device credential.
///
/// Claude's ruling on the shape (7149939807): **gated by default**. Every mutating request through the API
/// client needs a fresh local auth; a call that genuinely must run without a person in front of the phone
/// carries an [AuthExempt] marker **that names the exact endpoints it covers**, and a test pins the list so
/// adding one is a visible diff. The alternative — an opt-in `Mutation` intent — fails one forgotten screen
/// at a time, which is exactly what this guard exists to prevent.
library;

/// One call an exemption is allowed to cover: an exact method on one path shape.
///
/// A pattern is a list of `/`-separated segments in which `:name` matches exactly one non-empty segment
/// (an id, a token). A pattern never matches a different number of segments, so `/v1/alerts/:id/ack` does
/// not cover `/v1/alerts/ack` or `/v1/alerts/9/7/ack`; a query string is ignored, because it selects within
/// the call rather than naming another one.
class ExemptEndpoint {
  const ExemptEndpoint(this.method, this.pathPattern);

  /// The only verb this endpoint covers, upper-case by convention.
  final String method;

  /// The path shape this endpoint covers, with `:name` standing for one segment.
  final String pathPattern;

  /// True when [requestMethod] on [path] is exactly the call this endpoint names.
  bool matches(String requestMethod, String? path) {
    if (requestMethod.toUpperCase() != method) return false;
    if (path == null) return false;
    final wanted = _segments(pathPattern);
    final got = _segments(path);
    if (wanted.length != got.length) return false;
    for (var i = 0; i < wanted.length; i++) {
      final pattern = wanted[i];
      if (pattern.startsWith(':')) {
        if (!_isSafePathSegment(got[i])) return false;
      } else if (pattern != got[i]) {
        return false;
      }
    }
    return true;
  }

  /// One id-shaped segment, and nothing a client or a proxy could normalise into a different call.
  ///
  /// Ahmed's re-review of #1114: `/v1/alerts/../ack` matches the pattern as text, but an HTTP client or a
  /// proxy may fold the `..` and send a different path. `.`, `..`, an encoded separator (`%2F`, `%5C`, either
  /// case) and an encoded dot that decodes into a traversal (`%2E%2E`) are all refused. Refusing is the
  /// gated side, so a future caller sees a prompt rather than a silent pass. Double-encoding (`%252E`) is not
  /// decoded here; a proxy that decodes twice is outside what this check can promise.
  static bool _isSafePathSegment(String segment) {
    if (segment.isEmpty) return false;
    final upper = segment.toUpperCase();
    if (upper.contains('%2F') || upper.contains('%5C')) return false;
    final decoded = upper.replaceAll('%2E', '.');
    return decoded != '.' && decoded != '..' && !decoded.contains('..');
  }

  /// Drops the query and fragment, then splits on `/`. Empty segments are dropped so one trailing slash
  /// cannot make `/v1/me/push-token/` read as a different call than `/v1/me/push-token`.
  static List<String> _segments(String path) {
    var bare = path;
    final cut = bare.indexOf(RegExp('[?#]'));
    if (cut >= 0) bare = bare.substring(0, cut);
    return bare.split('/').where((segment) => segment.isNotEmpty).toList();
  }
}

/// Why a mutating call is allowed to run without a local auth prompt, and exactly which calls it covers.
///
/// Every value here is a claim that no human decision is being taken: the app is finishing work the parent
/// already authorised (a queued acknowledgement), registering or removing this device's own push token, or
/// refreshing a session. Anything that changes a rule, unlinks a device or pauses protection must **not** be
/// exempt, and adding a reason — or widening one to another endpoint — is a reviewable change on purpose.
///
/// Ahmed's R3 review of #1114 (2026-11-25) is why each value carries its endpoints: an unbound marker let any
/// caller attach it to any mutation and skip the prompt. A marker now frees only the calls named here, and
/// [MutationAuthPolicy.requiresAuth] fails closed for everything else.
class AuthExempt {
  const AuthExempt._(this.reason, this.endpoints);

  /// The reason string sent to logs and asserted in tests.
  final String reason;

  /// The exact calls this exemption covers. Empty would be meaningless, so a test pins non-emptiness.
  final List<ExemptEndpoint> endpoints;

  /// Acknowledging an alert from a notification action: the parent already chose to acknowledge it.
  static const acknowledgeFromNotification = AuthExempt._('ack-from-notification', [
    ExemptEndpoint('POST', '/v1/alerts/:id/ack'),
  ]);

  /// This device's own push token: minted by the OS, never by a parent. The removal is exempt for the same
  /// reason and because logout unregisters it before the access token is revoked (`auth_provider.dart:229`).
  static const pushToken = AuthExempt._('push-token', [
    ExemptEndpoint('POST', '/v1/me/push-token'),
    ExemptEndpoint('DELETE', '/v1/me/push-token'),
  ]);

  /// Session/token refresh, which must run to keep the session alive at all.
  static const tokenRefresh = AuthExempt._('token-refresh', [
    ExemptEndpoint('POST', '/v1/auth/token/refresh'),
  ]);

  /// Signing out. It only removes access, so it cannot loosen a restriction, and a parent on a phone with no
  /// screen lock could otherwise never leave the session: the refusal path would gate every attempt to sign
  /// out. Claude's ruling of 2026-11-25 (7157129055), with UI/UX behind it.
  static const sessionEnd = AuthExempt._('session-end', [
    ExemptEndpoint('POST', '/v1/auth/logout'),
  ]);

  /// The full set. A test pins this so a new exemption, or a widened one, cannot arrive unreviewed.
  static const all = <AuthExempt>[
    acknowledgeFromNotification,
    pushToken,
    tokenRefresh,
    sessionEnd,
  ];

  /// True only when this marker names [method] on [path]. Used to *narrow* a pass, never to grant one:
  /// [MutationAuthPolicy.requiresAuth] gates every request this does not match.
  bool covers(String method, String? path) =>
      endpoints.any((endpoint) => endpoint.matches(method, path));

  @override
  String toString() => 'AuthExempt($reason)';
}

/// Which requests need the owner's presence. Pure, so the rule is a unit row rather than a code review.
class MutationAuthPolicy {
  const MutationAuthPolicy._();

  /// Methods that cannot change anything, and therefore never prompt.
  static const safeMethods = <String>{'GET', 'HEAD', 'OPTIONS'};

  /// True when [method] on [path] must be preceded by a fresh local auth.
  ///
  /// [exempt] is the marker the caller passed, if any. A safe method is never gated even if marked, because
  /// prompting on a read would train the parent to approve reflexively — which is the failure mode this
  /// whole feature is trying not to create.
  ///
  /// A marker frees a request only when it names that exact method and path. A marker somewhere else — a
  /// different path, a different verb, or with no path at all — leaves the request gated (Ahmed, R3 review
  /// of #1114): the path is consulted only to narrow an exemption, never to grant one, so this does not
  /// reopen the "one forgotten screen" hole the gate exists to close.
  static bool requiresAuth({
    required String method,
    String? path,
    AuthExempt? exempt,
  }) {
    if (safeMethods.contains(method.toUpperCase())) return false;
    if (exempt != null && exempt.covers(method, path)) return false;
    // Nothing else is special-cased. A path allowlist here — a list of paths that skip the check — would be
    // the "one forgotten screen" bug in a different costume: the guard must fail closed for every mutating
    // call anyone adds later.
    return true;
  }
}
