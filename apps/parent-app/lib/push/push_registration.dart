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
abstract class PushTokenSource {
  /// Ask the OS. Must not throw: a refusal is [PushPermission.denied].
  Future<PushPermission> requestPermission();

  /// The token to forward, or null when none has been minted yet.
  Future<String?> token();
}

/// The source used until a push SDK is added.
class UnavailablePushTokenSource implements PushTokenSource {
  const UnavailablePushTokenSource();

  @override
  Future<PushPermission> requestPermission() async => PushPermission.unavailable;

  @override
  Future<String?> token() async => null;
}

/// The `platform` value `POST /v1/me/push-token` expects for a running target.
PushPlatform pushPlatformFor(TargetPlatform target) =>
    target == TargetPlatform.iOS ? PushPlatform.ios : PushPlatform.android;

/// What one registration attempt did. Every path returns one; none throws.
enum PushRegistrationOutcome {
  /// Permission granted, a token was minted, and the server accepted it.
  registered,

  /// The parent refused the OS prompt. Do not ask again in this session.
  denied,

  /// No push SDK in this build ([UnavailablePushTokenSource]), or session ended.
  unavailable,

  /// Permission granted but the SDK has not produced a token.
  noToken,

  /// The route refused, or the network failed. The token is not registered.
  failed,
}

/// Push registration over the interface the server already has.
class PushRegistration {
  PushRegistration({
    required PushApi api,
    PushTokenSource source = const UnavailablePushTokenSource(),
    PushPlatform? platform,
    String? appVersion,
    Future<bool> Function()? canPostRefreshedToken,
  })  : _api = api,
        _source = source,
        _platform = platform ?? pushPlatformFor(defaultTargetPlatform),
        _appVersion = appVersion,
        _canPostRefreshedToken = canPostRefreshedToken;

  final PushApi _api;
  final PushTokenSource _source;
  final PushPlatform _platform;
  final String? _appVersion;
  final Future<bool> Function()? _canPostRefreshedToken;

  /// Monotonic session epoch bumped at the start of [unregister] so an in-flight
  /// registration started before logout can never attach a token to a departed session.
  int _sessionEpoch = 0;

  /// Tracks an in-flight `POST /v1/me/push-token` call so [unregister] can await
  /// it (while the session bearer token is still valid) and remove that row too.
  Future<void>? _inFlightRegister;
  String? _inFlightToken;

  /// The token this instance forwarded, so [unregister] removes only a row the
  /// server is known to hold.
  String? _registeredToken;

  /// The token this instance registered, for [unregister].
  String? get registeredToken => _registeredToken;

  /// Permission -> token -> forward. Never throws: a push token is not a
  /// precondition for being signed in.
  Future<PushRegistrationOutcome> register() async {
    final epoch = _sessionEpoch;
    final permission = await _source.requestPermission();
    if (_sessionEpoch != epoch) return PushRegistrationOutcome.unavailable;
    if (permission == PushPermission.unavailable) return PushRegistrationOutcome.unavailable;
    if (permission == PushPermission.denied) return PushRegistrationOutcome.denied;

    final token = await _source.token();
    if (_sessionEpoch != epoch) return PushRegistrationOutcome.unavailable;
    if (token == null || token.isEmpty) return PushRegistrationOutcome.noToken;

    return _postTokenForEpoch(token: token, epoch: epoch);
  }

  /// Ensures the current or [refreshedToken] is registered with the server (#1173).
  Future<PushRegistrationOutcome> ensureRegistered({String? refreshedToken}) async {
    final epoch = _sessionEpoch;
    if (refreshedToken != null && refreshedToken.isNotEmpty) {
      if (_sessionEpoch != epoch) return PushRegistrationOutcome.unavailable;
      if (_canPostRefreshedToken != null && !await _canPostRefreshedToken()) {
        return PushRegistrationOutcome.denied;
      }
      if (_sessionEpoch != epoch) return PushRegistrationOutcome.unavailable;
      if (refreshedToken == _registeredToken) {
        return PushRegistrationOutcome.registered;
      }
      return _postTokenForEpoch(token: refreshedToken, epoch: epoch);
    }

    final permission = await _source.requestPermission();
    if (_sessionEpoch != epoch) return PushRegistrationOutcome.unavailable;
    if (permission == PushPermission.unavailable) {
      return PushRegistrationOutcome.unavailable;
    }
    if (permission == PushPermission.denied) {
      return PushRegistrationOutcome.denied;
    }

    final token = await _source.token();
    if (_sessionEpoch != epoch) return PushRegistrationOutcome.unavailable;
    if (token == null || token.isEmpty) {
      return PushRegistrationOutcome.noToken;
    }
    if (token == _registeredToken) {
      return PushRegistrationOutcome.registered;
    }

    return _postTokenForEpoch(token: token, epoch: epoch);
  }

  Future<PushRegistrationOutcome> _postTokenForEpoch({
    required String token,
    required int epoch,
  }) async {
    if (_sessionEpoch != epoch) return PushRegistrationOutcome.unavailable;
    final req = _api.register(
      token: token,
      platform: _platform,
      appVersion: _appVersion,
    );
    _inFlightRegister = req;
    _inFlightToken = token;
    try {
      await req;
    } catch (_) {
      return PushRegistrationOutcome.failed;
    } finally {
      if (identical(_inFlightRegister, req)) {
        _inFlightRegister = null;
        _inFlightToken = null;
      }
    }
    if (_sessionEpoch != epoch) {
      _registeredToken = null;
      return PushRegistrationOutcome.unavailable;
    }
    _registeredToken = token;
    return PushRegistrationOutcome.registered;
  }

  /// Removes this instance's token. Call it **before** the session is cleared:
  /// the route authenticates as the parent it is removing the token for.
  Future<bool> unregister() async {
    _sessionEpoch += 1;
    final pendingReq = _inFlightRegister;
    final pendingTok = _inFlightToken;
    if (pendingReq != null) {
      try {
        await pendingReq;
      } catch (_) {}
    }
    final tokens = <String>{
      if (_registeredToken != null && _registeredToken!.isNotEmpty)
        _registeredToken!,
      if (pendingTok != null && pendingTok.isNotEmpty) pendingTok,
    };
    if (tokens.isEmpty) {
      _registeredToken = null;
      _inFlightRegister = null;
      _inFlightToken = null;
      return false;
    }
    var removedAny = false;
    try {
      for (final token in tokens) {
        try {
          final removed = await _api.remove(token);
          if (removed > 0) removedAny = true;
        } catch (_) {}
      }
      return removedAny;
    } finally {
      _registeredToken = null;
      _inFlightRegister = null;
      _inFlightToken = null;
    }
  }
}