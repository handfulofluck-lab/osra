import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// `/v1/auth/*` paths whose 401 is the answer, not an expired session.
///
/// These routes authenticate with a credential in the request (a password, a
/// recovery code, a mailbox or cancel link, the refresh token itself) and the
/// parent being reset deliberately holds no session. A token refresh could not
/// help them, and replaying the call after one would turn "wrong password" into
/// a second attempt at the same wrong password. Everything else under
/// `/v1/auth/*` — `/mfa/reset/pending`, `/mfa/reset/approve`, the session form
/// of `/mfa/reset/cancel`, `/mfa/recovery-codes`, `/logout-all`, and
/// `/mfa/enroll` + `/mfa/verify` when they carry the parent session — refreshes
/// like any signed-in call.
const Set<String> credentialOnlyAuthPaths = {
  '/v1/auth/register',
  '/v1/auth/login',
  '/v1/auth/logout',
  '/v1/auth/token/refresh',
  '/v1/auth/reset/request',
  '/v1/auth/reset/confirm',
  '/v1/auth/mfa/recover',
  '/v1/auth/mfa/reset/request',
  '/v1/auth/mfa/reset/confirm',
  '/v1/auth/mfa/reset/witness',
  '/v1/auth/mfa/reset/status',
  '/v1/auth/mfa/reset/complete',
};

/// Whether a 401 on [options] should trigger the stored-session refresh.
///
/// The exemption is per route, not the whole `/v1/auth/` prefix: two routes
/// share a path with different authentication. `/mfa/reset/cancel` is the
/// emailed-link form when the body has `token` (no session) and the
/// owner/co-parent form when it has `requestId` (session). A purpose-scoped
/// token in `extra['authToken']` (the 15-minute `mfa_recovery` credential) is
/// never swapped for the stored session.
bool shouldRefreshOn401(RequestOptions options) {
  final scoped = options.extra['authToken'];
  if (scoped is String && scoped.isNotEmpty) return false;
  if (options.extra['retried'] == true) return false;
  final path = options.path;
  if (path == '/v1/auth/mfa/reset/cancel') {
    final body = options.data;
    final linkForm = body is Map && body.containsKey('token') && !body.containsKey('requestId');
    return !linkForm;
  }
  return !credentialOnlyAuthPaths.contains(path);
}

class ApiClient {
  static const _base = String.fromEnvironment('API_BASE', defaultValue: '');
  final _dio = Dio(BaseOptions(baseUrl: _base));
  final _storage = const FlutterSecureStorage();
  Future<String?>? _refreshFuture;

  Future<String?> _refreshToken() async {
    String? refresh;
    try {
      refresh = await _storage.read(key: 'refresh');
    } catch (_) {}
    if (refresh == null) return null;
    try {
      final resp = await _dio.post('/v1/auth/token/refresh', data: {'refreshToken': refresh});
      final data = resp.data is Map ? resp.data as Map : const <String, dynamic>{};
      final token = data['token'] as String?;
      if (token == null) throw const FormatException('refresh response missing token');
      await _storage.write(key: 'jwt', value: token);
      final newRefresh = data['refreshToken'] as String?;
      if (newRefresh != null) await _storage.write(key: 'refresh', value: newRefresh);
      return token;
    } catch (_) {
      try {
        await _storage.delete(key: 'jwt');
        await _storage.delete(key: 'refresh');
      } catch (_) {}
      rethrow;
    }
  }

  ApiClient() {
    _dio.interceptors.add(InterceptorsWrapper(
      onRequest: (opts, handler) async {
        // A purpose-scoped token (the 15-minute `mfa_recovery` credential) is
        // passed per request and must win over the stored session: it is not a
        // session, and it must never be written to the 'jwt' key.
        final scoped = opts.extra['authToken'];
        final token = scoped is String && scoped.isNotEmpty
            ? scoped
            : await _storage.read(key: 'jwt');
        if (token != null && token.isNotEmpty) {
          opts.headers['Authorization'] = 'Bearer $token';
        }
        handler.next(opts);
      },
      onError: (e, handler) async {
        final res = e.response;
        if (res == null || res.statusCode != 401) return handler.next(e);
        // Credential-only auth routes (and the refresh call itself) answer their
        // own 401; session-carrying auth routes below refresh like any other.
        if (!shouldRefreshOn401(e.requestOptions)) return handler.next(e);

        try {
          _refreshFuture ??= _refreshToken().whenComplete(() {
            _refreshFuture = null;
          });
          final newToken = await _refreshFuture;
          if (newToken == null) return handler.next(e);
          e.requestOptions.extra['retried'] = true;
          e.requestOptions.headers['Authorization'] = 'Bearer $newToken';
          return handler.resolve(await _dio.fetch<dynamic>(e.requestOptions));
        } catch (_) {
          return handler.next(e);
        }
      },
    ));
  }

  Dio get raw => _dio;
}
