import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';

import 'mutation_auth.dart';

/// Issue #742: the owner-presence gate. A mutating request waits for the phone's owner, and a phone with
/// **no biometrics and no screen lock refuses** — Claude's ruling (7149939807, 2026-11-25): never fall back to
/// the app's own PIN, because a PIN a child may have watched being typed is weaker than the promise.
enum OwnerPresence {
  /// The OS accepted the biometric or the device credential.
  authorised,

  /// The prompt ran and the parent dismissed or failed it.
  cancelled,

  /// There is nothing to ask for: no biometrics enrolled and no screen lock configured.
  unavailable,
}

/// Thrown into the request path when a mutation was not authorised. Carries [result] so the UI can tell
/// "try again" apart from "set a screen lock first" instead of showing one generic failure for both.
class OwnerPresenceRequired implements Exception {
  const OwnerPresenceRequired(this.result);

  final OwnerPresence result;

  @override
  String toString() => 'OwnerPresenceRequired(${result.name})';
}

/// Asks the OS, and maps its answers to the three outcomes above.
///
/// The two questions are held as functions rather than as a plugin object, so a test drives every answer
/// without faking a plugin class whose signature moves between versions ([OwnerPresenceGate.forTest]). The
/// decisions that matter — which plugin failure means "nothing to ask for" — are unit rows either way.
class OwnerPresenceGate {
  OwnerPresenceGate({LocalAuthentication? auth})
      : _auth = auth ?? LocalAuthentication(),
        _isSupported = null,
        _authenticate = null;

  /// A gate over two functions: what a test uses, and what the production constructor wraps.
  OwnerPresenceGate.forTest({
    required Future<bool> Function() isSupported,
    required Future<bool> Function(String reason) authenticate,
  })  : _auth = null,
        _isSupported = isSupported,
        _authenticate = authenticate;

  final LocalAuthentication? _auth;
  final Future<bool> Function()? _isSupported;
  final Future<bool> Function(String reason)? _authenticate;

  /// Whether the phone can answer a prompt at all right now. The refusal screen asks this when the parent comes
  /// back from Settings: a lock that now exists means the refused save can be repeated with one prompt.
  Future<bool> canAsk() async {
    final supported = _isSupported ?? _auth!.isDeviceSupported;
    try {
      return await supported();
    } on LocalAuthException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// [reason] is shown inside the OS prompt, so the caller passes localised copy.
  Future<OwnerPresence> authorise(String reason) async {
    final plugin = _auth;
    final isSupported = _isSupported ?? plugin!.isDeviceSupported;
    final authenticate = _authenticate ??
        (String localizedReason) => plugin!.authenticate(
              localizedReason: localizedReason,
              // The device credential is the floor, not the biometric: a phone with a PIN and no fingerprint
              // still has an owner who can prove it.
              biometricOnly: false,
              // A call or the app switcher must not cancel the prompt for good; the parent comes back to it
              // (this API's name for what used to be `stickyAuth`).
              persistAcrossBackgrounding: true,
            );

    final bool supported;
    try {
      supported = await isSupported();
    } on LocalAuthException {
      return OwnerPresence.unavailable;
    } on PlatformException {
      return OwnerPresence.unavailable;
    }
    if (!supported) return OwnerPresence.unavailable;
    try {
      final ok = await authenticate(reason);
      return ok ? OwnerPresence.authorised : OwnerPresence.cancelled;
    } on LocalAuthException catch (e) {
      // The plugin's "cannot answer" codes are the refuse case; anything else is a failed attempt. An
      // unlisted future code falls to `cancelled`, which asks again rather than locking the parent out.
      return switch (e.code) {
        LocalAuthExceptionCode.noCredentialsSet ||
        LocalAuthExceptionCode.noBiometricsEnrolled ||
        LocalAuthExceptionCode.noBiometricHardware ||
        LocalAuthExceptionCode.uiUnavailable =>
          OwnerPresence.unavailable,
        _ => OwnerPresence.cancelled,
      };
    } on PlatformException {
      // An older platform channel surfaces a PlatformException; without the richer codes it is a failed attempt.
      return OwnerPresence.cancelled;
    }
  }
}

/// The decision for one request, separated from dio and from the plugin so it is a unit row.
///
/// [exempt] is whatever the caller put in `RequestOptions.extra['authExempt']`; anything that is not an
/// [AuthExempt] is treated as absent, so a caller cannot pass a string and buy a pass.
///
/// Throws [OwnerPresenceRequired] when the owner did not authorise, which is what stops the request: the
/// exception leaves the dio interceptor before any byte is written.
Future<void> guardMutation({
  required String method,
  required String? path,
  required Object? exempt,
  required Future<OwnerPresence> Function(String reason) askOwner,
  required String reason,
}) async {
  final marker = exempt is AuthExempt ? exempt : null;
  if (!MutationAuthPolicy.requiresAuth(method: method, path: path, exempt: marker)) return;
  final result = await askOwner(reason);
  if (result != OwnerPresence.authorised) throw OwnerPresenceRequired(result);
}
