import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' hide Family;

import '../api/client.dart';
import '../api/models.dart';
import '../api/permission_errors.dart';
import '../api/push_api.dart';
import '../push/push_registration.dart';
import '../push/fcm_push_token_source.dart';
import 'server_provider.dart';

/// Injectable [ApiClient] source; overridden in tests with a fake.
final apiClientProvider = Provider<ApiClient>((ref) => ApiClient());

/// [AuthState.error] prefix for a 400 whose body is zod's `flatten()` output: the rejected field
/// names follow, sorted and comma-separated (`validation_failed:email,password`). The login screen
/// turns it into a sentence naming the field; a bare "Validation failed" told a parent nothing
/// (the 2026-10-23 setup run, where the password was under the server's 12 characters).
const kValidationFailedPrefix = 'validation_failed:';

/// Immutable authentication state for the signed-in parent.
@immutable
class AuthState {
  final bool isAuthenticated;
  final Parent? parent;
  final Family? family;
  final String? error;
  final bool loading;

  /// `bootstrap()` has not answered yet. The router holds a neutral screen
  /// until this is false so a resumed session does not flash the login step.
  final bool restoring;

  const AuthState({
    this.isAuthenticated = false,
    this.parent,
    this.family,
    this.error,
    this.loading = false,
    this.restoring = false,
  });

  AuthState copyWith({
    bool? isAuthenticated,
    Parent? parent,
    Family? family,
    Object? error = _sentinel,
    bool? loading,
    bool? restoring,
  }) {
    return AuthState(
      isAuthenticated: isAuthenticated ?? this.isAuthenticated,
      parent: parent ?? this.parent,
      family: family ?? this.family,
      error: identical(error, _sentinel) ? this.error : error as String?,
      loading: loading ?? this.loading,
      restoring: restoring ?? this.restoring,
    );
  }
}

const _sentinel = Object();

/// Listenable that fires on AuthState changes to trigger GoRouter refresh.
class AuthRouterListenable extends ChangeNotifier {
  void notify() => notifyListeners();
}

final authRouterListenable = AuthRouterListenable();

/// Signs the parent in/out, stores the JWT ('jwt' key) and refresh token
/// ('refresh' key) in secure storage and bootstraps the session from a
/// persisted token.
class AuthNotifier extends StateNotifier<AuthState> {
  final ApiClient _api;
  final FlutterSecureStorage _storage;
  final ServerUrlNotifier? _serverUrl;

  /// The push seam. Injectable so a test can supply a token source and see the
  /// forward happen; the default has no SDK behind it and therefore makes no
  /// request (`lib/push/push_registration.dart`).
  PushRegistration? _push;

  AuthNotifier(
    this._api, {
    FlutterSecureStorage? storage,
    ServerUrlNotifier? serverUrl,
    PushRegistration? push,
  })  : _storage = storage ?? const FlutterSecureStorage(),
        _serverUrl = serverUrl,
        _push = push,
        super(const AuthState(restoring: true));

  PushRegistration get _pushRegistration =>
      _push ??= PushRegistration(api: PushApi(_api), source: defaultPushSource());

  /// Synchronises push token registration when the signed-in parent has
  /// finished onboarding or granted notifications in system settings (#1173).
  Future<PushRegistrationOutcome> syncPushRegistration({
    String? refreshedToken,
  }) async {
    if (_disposed || !state.isAuthenticated) {
      return PushRegistrationOutcome.unavailable;
    }
    return _pushRegistration.ensureRegistered(refreshedToken: refreshedToken);
  }

  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  /// Sets state unless disposed; the fire-and-forget bootstrap() can finish
  /// after a scoped ProviderContainer is torn down (e.g. in tests).
  void _setState(AuthState next) {
    if (_disposed) return;
    state = next;
    authRouterListenable.notify();
  }

  /// Applies the effective server URL to the shared Dio client before requests.
  Future<void> _applyServerUrl() async {
    await _serverUrl?.ensureApplied();
  }

  /// POSTs /v1/auth/login then bootstraps the family session. When [code] is
  /// non-empty (MFA) it is included in the request body as `code`.
  /// Drops the last auth error, so a screen opened after a failed sign-in does not inherit its message.
  void clearError() => _setState(state.copyWith(error: null));

  Future<void> login(String email, String password, [String? code]) => _authenticate(() {
        final body = <String, dynamic>{'email': email, 'password': password};
        final trimmed = code?.trim();
        if (trimmed != null && trimmed.isNotEmpty) body['code'] = trimmed;
        return _api.raw.post('/v1/auth/login', data: body);
      });

  /// POSTs /v1/auth/register (creates family + owner parent) then bootstraps.
  ///
  /// ADR-0043 D4: registration carries the consent it showed. The version is the one the copy served; the
  /// server answers `400 consent_text_outdated` for an old one, and the screen refetches.
  Future<void> register({
    required String email,
    required String password,
    required String displayName,
    required String familyName,
    required String region,
    required String consentTextVersion,
    required String consentLocale,
  }) =>
      _authenticate(() => _api.raw.post('/v1/auth/register', data: {
            'email': email,
            'password': password,
            'displayName': displayName,
            'familyName': familyName,
            'region': region,
            'consents': {
              'termsPrivacy': true,
              'textVersion': consentTextVersion,
              'locale': consentLocale,
            },
          }));

  /// Runs an auth call, persists the returned token, then loads /v1/family/me.
  Future<void> _authenticate(Future<Response<dynamic>> Function() call) async {
    await _applyServerUrl();
    _setState(state.copyWith(loading: true, error: null, restoring: false));
    try {
      final res = await call();
      final data = res.data is Map ? res.data as Map : const <String, dynamic>{};
      final token = data['token'] as String?;
      if (token == null) {
        throw const FormatException('auth response missing token');
      }
      await _storage.write(key: 'jwt', value: token);
      final refresh = data['refreshToken'] as String?;
      if (refresh != null) await _storage.write(key: 'refresh', value: refresh);
      await bootstrap();
    } on DioException catch (e) {
      _setState(AuthState(error: _errorMessage(e)));
    } catch (e) {
      logParentError(e);
      _setState(const AuthState(error: 'unexpected_error'));
    }
  }

  /// Loads GET /v1/family/me with the stored token; clears it on 401.
  Future<void> bootstrap() async {
    try {
      await _applyServerUrl();
    } catch (_) {
      // A broken server-URL read must not leave the app on the startup frame.
      _setState(const AuthState());
      return;
    }
    String? token;
    try {
      token = await _storage.read(key: 'jwt');
    } catch (_) {
      token = null; // secure storage unavailable (e.g. tests) — stay logged out
    }
    if (token == null) {
      _setState(const AuthState());
      return;
    }
    try {
      final res = await _api.raw.get('/v1/family/me');
      final overview = FamilyOverview.fromJson(Map<String, dynamic>.from(res.data as Map));
      _setState(AuthState(isAuthenticated: true, parent: overview.parent, family: overview.family));
      // #1173: Notification permission prompting and token registration are
      // coordinated by NotificationPermissionController once the parent is
      // signed in and past first-run family setup (never during onboarding or
      // cold start before sign-in), and re-checked on AppLifecycleState.resumed.
    } on DioException catch (e) {
      if (e.response?.statusCode == 401) {
        try {
          await _storage.delete(key: 'jwt');
          await _storage.delete(key: 'refresh');
        } catch (_) {}
      }
      _setState(AuthState(error: _errorMessage(e)));
    } catch (e) {
      logParentError(e);
      _setState(const AuthState(error: 'unexpected_error'));
    }
  }

  /// Deletes the stored tokens and resets to the logged-out state.
  Future<void> logout() async {
    // Before logout: `/v1/auth/logout` revokes the access token issued with this
    // refresh token (`services/api/src/routes/auth.ts:1442`, ADR-0014), and
    // `DELETE /v1/me/push-token` authenticates with it — so the removal has to
    // go first or it is a 401 and the row survives on a signed-out phone.
    try {
      await _push?.unregister();
    } catch (_) {}
    // Handoff item 2: revoke the refresh token server-side before clearing locally.
    try {
      final refresh = await _storage.read(key: 'refresh');
      if (refresh != null) {
        await _api.raw.post('/v1/auth/logout', data: {'refreshToken': refresh});
      }
    } catch (_) {}
    try {
      await _storage.delete(key: 'jwt');
      await _storage.delete(key: 'refresh');
    } catch (_) {}
    _setState(const AuthState());
  }

  /// Structured token for a failed auth response; technical text is logged only.
  static String _errorMessage(DioException e) {
    logParentError(e);
    if (isNetworkDioError(e)) return 'network_error';
    final data = e.response?.data;
    if (data is Map) {
      final err = data['error'];
      if (err is String) {
        if (err == 'mfa_reenroll_required') {
          return 'Two-step verification was reset but not finished. Open "Lost your authenticator?" if '
              'you still have the setup screen open; otherwise contact support.';
        }
        final lower = err.toLowerCase();
        if (e.response?.statusCode == 401 && (lower.contains('mfa') || lower == 'invalid_code')) {
          return 'Invalid authentication code';
        }
        if (err == 'invalid_credentials' ||
            err == 'email_taken' ||
            err == 'mfa_required' ||
            err == 'consent_text_outdated') {
          return err;
        }
      }
      if (err is Map && err['fieldErrors'] is Map) {
        final fields = (err['fieldErrors'] as Map).keys.map((k) => '$k').toList()..sort();
        return '$kValidationFailedPrefix${fields.join(',')}';
      }
    }
    return 'request_failed';
  }
}

/// Global auth state; bootstrap() runs at creation to restore a saved session.
/// Injectable [PushTokenSource] for [authProvider]; overridden in tests (#1173).
final pushTokenSourceProvider = Provider<PushTokenSource>(
  (_) => defaultPushSource(),
);

final authProvider = StateNotifierProvider<AuthNotifier, AuthState>((ref) {
  final api = ref.watch(apiClientProvider);
  final notifier = AuthNotifier(
    api,
    serverUrl: ref.watch(serverUrlProvider.notifier),
    push: PushRegistration(
      api: PushApi(api),
      source: ref.watch(pushTokenSourceProvider),
    ),
  );
  notifier.bootstrap();
  return notifier;
});
