/// Issue #742 — a mutation from the parent app must be authorised by the phone's owner before it is sent.
///
/// Karim's decision (13 Nov, card log in #617): before any rule change, unlinking a device or pausing, the
/// app asks for the phone's own biometric or device credential.
///
/// Claude's ruling on the shape (7149939807): **gated by default**. Every mutating request through the API
/// client needs a fresh local auth; a call that genuinely must run without a person in front of the phone
/// carries an [AuthExempt] marker, and a test pins the list of those markers so adding one is a visible diff.
/// The alternative — an opt-in `Mutation` intent — fails one forgotten screen at a time, which is exactly
/// what this guard exists to prevent.
library;

/// Why a mutating call is allowed to run without a local auth prompt.
///
/// Every value here is a claim that no human decision is being taken: the app is finishing work the parent
/// already authorised (a queued acknowledgement), registering something the OS produced (a push token), or
/// refreshing a session. Anything that changes a rule, unlinks a device or pauses protection must **not** be
/// exempt, and adding a reason here is a reviewable change on purpose.
class AuthExempt {
  const AuthExempt._(this.reason);

  /// The reason string sent to logs and asserted in tests.
  final String reason;

  /// Acknowledging an alert from a notification action: the parent already chose to acknowledge it.
  static const acknowledgeFromNotification = AuthExempt._('ack-ack-0052');

  /// Push-token registration: the token is minted by the OS, not by a parent.
  static const pushToken = AuthExempt._('push-token');

  /// Background refresh writes (telemetry-adjacent bookkeeping, not a setting).
  static const backgroundRefresh = AuthExempt._('background-refresh');

  /// Session/token refresh, which must run to keep the session alive at all.
  static const tokenRefresh = AuthExempt._('token-refresh');

  /// The full set. A test pins this so a new exemption cannot arrive unreviewed.
  static const all = <AuthExempt>[
    acknowledgeFromNotification,
    pushToken,
    backgroundRefresh,
    tokenRefresh,
  ];

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
  static bool requiresAuth({
    required String method,
    String? path,
    AuthExempt? exempt,
  }) {
    if (safeMethods.contains(method.toUpperCase())) return false;
    if (exempt != null) return false;
    // Nothing else is special-cased. A path allowlist here would be the "one forgotten screen" bug in a
    // different costume: the guard must fail closed for every mutating call anyone adds later.
    return true;
  }
}
