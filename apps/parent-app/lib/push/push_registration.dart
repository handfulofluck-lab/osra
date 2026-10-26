import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform;

import '../api/push_api.dart';

/// The answer to the OS permission prompt.
enum PushPermission {
  granted,
  denied,

  /// This build carries no push SDK, so no prompt can be shown at all. Distinct
  /// from [denied] on purpose: "we never asked" and "the parent said no" are
  /// different facts to report, and only the second is the parent's choice.
  unavailable,
}

/// What a platform push SDK has to provide.
///
/// The whole point of this interface is that the forwarding logic below (in
/// [PushRegistration]) is platform-agnostic and testable without a plugin: an
/// APNs source and an FCM source differ in how they ask for permission and
/// where the token comes from, not in what happens next.
///
/// Since #360 the shipped implementation is [FcmPushTokenSource], backed by
/// `firebase_messaging` on Android and on iOS, and [defaultPushSource] is the
/// seam a test replaces. [UnavailablePushTokenSource] remains for the case where
/// Firebase has no configuration at all, so an unsupported build reports
/// [PushPermission.unavailable] instead of pretending a token exists.
abstract class PushTokenSource {
  /// Ask the OS. Must not throw: a refusal is [PushPermission.denied].
  Future<PushPermission> requestPermission();

  /// The token to forward, or null when none has been minted yet — an APNs
  /// registration is asynchronous and can also fail without an error the app
  /// is allowed to see.
  Future<String?> token();
}

/// The source used until a push SDK is added. It grants nothing and mints
/// nothing, so [PushRegistration.register] returns `unavailable` before any
/// request — which is why wiring it into sign-in cannot change a session's
/// outcome.
class UnavailablePushTokenSource implements PushTokenSource {
  const UnavailablePushTokenSource();

  @override
  Future<PushPermission> requestPermission() async => PushPermission.unavailable;

  @override
  Future<String?> token() async => null;
}

/// The `platform` value `POST /v1/me/push-token` expects for a running target.
///
/// iOS is the only non-Android mobile target this app ships. Every other target
/// is reported as `android` — the other value the route accepts — rather than
/// `web`, which would make `notify.ts` route an APNs token to the FCM provider.
PushPlatform pushPlatformFor(TargetPlatform target) =>
    target == TargetPlatform.iOS ? PushPlatform.ios : PushPlatform.android;

/// What one registration attempt did. Every path returns one; none throws.
enum PushRegistrationOutcome {
  /// Permission granted, a token was minted, and the server accepted it.
  registered,

  /// The parent refused the OS prompt. Do not ask again in this session.
  denied,

  /// No push SDK in this build ([UnavailablePushTokenSource]).
  unavailable,

  /// Permission granted but the SDK has not produced a token.
  noToken,

  /// The route refused, or the network failed. The token is not registered.
  failed,
}

/// Push registration over the interface the server already has.
///
/// The order is fixed — permission, then a token, then the forward — so nothing
/// is sent unless the OS granted it and a token exists. The forward is the
/// existing `POST /v1/me/push-token`, which already accepts `platform: "ios"`,
/// so this is a seam for APNs rather than a second registration path.
class PushRegistration {
  PushRegistration({
    required PushApi api,
    PushTokenSource source = const UnavailablePushTokenSource(),
    PushPlatform? platform,
    String? appVersion,
  })  : _api = api,
        _source = source,
        _platform = platform ?? pushPlatformFor(defaultTargetPlatform),
        _appVersion = appVersion;

  final PushApi _api;
  final PushTokenSource _source;
  final PushPlatform _platform;
  final String? _appVersion;

  /// The token this instance forwarded, so [unregister] removes only a row the
  /// server is known to hold.
  String? _registeredToken;

  /// The token this instance registered, for [unregister].
  String? get registeredToken => _registeredToken;

  /// Permission → token → forward. Never throws: a push token is not a
  /// precondition for being signed in.
  Future<PushRegistrationOutcome> register() async {
    final permission = await _source.requestPermission();
    if (permission == PushPermission.unavailable) return PushRegistrationOutcome.unavailable;
    if (permission == PushPermission.denied) return PushRegistrationOutcome.denied;

    final token = await _source.token();
    if (token == null || token.isEmpty) return PushRegistrationOutcome.noToken;

    try {
      await _api.register(token: token, platform: _platform, appVersion: _appVersion);
    } catch (_) {
      return PushRegistrationOutcome.failed;
    }
    _registeredToken = token;
    return PushRegistrationOutcome.registered;
  }

  /// Removes this instance's token. Call it **before** the session is cleared:
  /// the route authenticates as the parent it is removing the token for.
  ///
  /// Returns whether a row was actually removed. A token forwarded by an
  /// earlier launch is not known here — a full logout-time removal across
  /// restarts needs the last token persisted, which this does not do (roadmap
  /// 3.9 says so).
  Future<bool> unregister() async {
    final token = _registeredToken;
    if (token == null) return false;
    try {
      final removed = await _api.remove(token);
      _registeredToken = null;
      return removed > 0;
    } catch (_) {
      return false;
    }
  }
}
