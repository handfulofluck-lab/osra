import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' hide Family;

import '../api/client.dart';
import '../api/models.dart';
import 'server_provider.dart';

/// Injectable [ApiClient] source; overridden in tests with a fake.
final apiClientProvider = Provider<ApiClient>((ref) => ApiClient());

/// Immutable authentication state for the signed-in parent.
@immutable
class AuthState {
  final bool isAuthenticated;
  final Parent? parent;
  final Family? family;
  final String? error;
  final bool loading;

  const AuthState({this.isAuthenticated = false, this.parent, this.family, this.error, this.loading = false});

  AuthState copyWith({bool? isAuthenticated, Parent? parent, Family? family, Object? error = _sentinel, bool? loading}) {
    return AuthState(
      isAuthenticated: isAuthenticated ?? this.isAuthenticated,
      parent: parent ?? this.parent,
      family: family ?? this.family,
      error: identical(error, _sentinel) ? this.error : error as String?,
      loading: loading ?? this.loading,
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

  AuthNotifier(this._api, {FlutterSecureStorage? storage, ServerUrlNotifier? serverUrl})
      : _storage = storage ?? const FlutterSecureStorage(),
        _serverUrl = serverUrl,
        super(const AuthState());

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
  Future<void> login(String email, String password, [String? code]) => _authenticate(() {
        final body = <String, dynamic>{'email': email, 'password': password};
        final trimmed = code?.trim();
        if (trimmed != null && trimmed.isNotEmpty) body['code'] = trimmed;
        return _api.raw.post('/v1/auth/login', data: body);
      });

  /// POSTs /v1/auth/register (creates family + owner parent) then bootstraps.
  Future<void> register({required String email, required String password, required String displayName, required String familyName, required String region}) =>
      _authenticate(() => _api.raw.post('/v1/auth/register', data: {
            'email': email,
            'password': password,
            'displayName': displayName,
            'familyName': familyName,
            'region': region,
          }));

  /// Runs an auth call, persists the returned token, then loads /v1/family/me.
  Future<void> _authenticate(Future<Response<dynamic>> Function() call) async {
    await _applyServerUrl();
    _setState(state.copyWith(loading: true, error: null));
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
      _setState(AuthState(error: e.toString()));
    }
  }

  /// Loads GET /v1/family/me with the stored token; clears it on 401.
  Future<void> bootstrap() async {
    await _applyServerUrl();
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
    } on DioException catch (e) {
      if (e.response?.statusCode == 401) {
        try {
          await _storage.delete(key: 'jwt');
          await _storage.delete(key: 'refresh');
        } catch (_) {}
      }
      _setState(AuthState(error: _errorMessage(e)));
    } catch (e) {
      _setState(AuthState(error: e.toString()));
    }
  }

  /// Deletes the stored tokens and resets to the logged-out state.
  Future<void> logout() async {
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

  /// Human-readable message from a failed auth response.
  static String _errorMessage(DioException e) {
    final data = e.response?.data;
    if (data is Map) {
      final err = data['error'];
      if (err is String) {
        final lower = err.toLowerCase();
        if (e.response?.statusCode == 401 && (lower.contains('mfa') || lower == 'invalid_code')) {
          return 'Invalid authentication code';
        }
        return err;
      }
      if (err is Map && err['fieldErrors'] is Map) return 'Validation failed';
      final msg = data['message'];
      if (msg is String) return msg;
    }
    return e.message ?? 'request failed';
  }
}

/// Global auth state; bootstrap() runs at creation to restore a saved session.
final authProvider = StateNotifierProvider<AuthNotifier, AuthState>((ref) {
  final notifier = AuthNotifier(
    ref.watch(apiClientProvider),
    serverUrl: ref.watch(serverUrlProvider.notifier),
  );
  notifier.bootstrap();
  return notifier;
});
