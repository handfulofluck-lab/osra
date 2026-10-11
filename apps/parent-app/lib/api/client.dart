import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

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
        final token = await _storage.read(key: 'jwt');
        if (token != null) opts.headers['Authorization'] = 'Bearer $token';
        handler.next(opts);
      },
      onError: (e, handler) async {
        final res = e.response;
        if (res == null || res.statusCode != 401) return handler.next(e);
        // Auth endpoints handle their own errors; never refresh-loop there.
        if (e.requestOptions.path.startsWith('/v1/auth/')) return handler.next(e);
        if (e.requestOptions.extra['retried'] == true) return handler.next(e);

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
