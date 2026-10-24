import 'package:dio/dio.dart';

import 'client.dart';

/// The `platform` value `POST /v1/me/push-token` accepts — a `z.enum` in
/// `services/api/src/routes/me.ts`, so an unknown string is a `400`, not a
/// silently-stored row.
enum PushPlatform {
  android('android'),

  /// What an APNs token registers as. The server already accepts it
  /// (`services/api/src/lib/push/notify.ts` falls back to the FCM provider for
  /// `ios` when no APNs provider is configured), so an iOS registration is a
  /// value this route already understood — not a new route.
  ios('ios'),
  web('web');

  const PushPlatform(this.wire);

  /// The string the route reads.
  final String wire;
}

/// Why a push-token call failed, reduced to what the route actually tells us.
enum PushFailureKind {
  /// `401` — no session, or one the refresh could not renew.
  unauthorized,

  /// `400` — the body did not match the route's schema: a token shorter than
  /// 20 or longer than 4096 characters, or an unknown platform.
  validation,

  /// The request never reached the server.
  network,

  /// A `2xx` whose body was not the shape the contract promises.
  malformed,

  /// Anything else, reported without inventing a cause.
  unknown,
}

class PushFailure implements Exception {
  final PushFailureKind kind;
  final int? statusCode;

  const PushFailure(this.kind, {this.statusCode});

  @override
  String toString() => 'PushFailure(${kind.name}, status: $statusCode)';
}

/// The parent-self push routes that already exist in
/// `services/api/src/routes/me.ts` (Phase 2a).
///
/// A token belongs to one parent, and re-registering an existing token moves it
/// to the caller — which is what makes this the right seam for a second
/// platform: the iOS build registers the same way the Android one will, and the
/// server decides from the `platform` field which provider delivers.
class PushApi {
  PushApi(this._client);

  final ApiClient _client;

  /// `POST /v1/me/push-token` → `201 {id, platform, registeredAt}`.
  Future<void> register({
    required String token,
    required PushPlatform platform,
    String? appVersion,
  }) async {
    final data = await _send('POST', {
      'token': token,
      'platform': platform.wire,
      if (appVersion != null && appVersion.isNotEmpty) 'appVersion': appVersion,
    });
    // The route answers with the row that now owns the token; anything else
    // means we cannot say the registration succeeded.
    if (data['id'] is! String) throw const PushFailure(PushFailureKind.malformed);
  }

  /// `DELETE /v1/me/push-token` → `{removed: n}`, `0` when the token was not
  /// this parent's. Called on logout so a shared phone stops receiving the
  /// previous parent's alerts.
  Future<int> remove(String token) async {
    final data = await _send('DELETE', {'token': token});
    final removed = data['removed'];
    if (removed is! int) throw const PushFailure(PushFailureKind.malformed);
    return removed;
  }

  Future<Map<String, dynamic>> _send(String method, Map<String, dynamic> body) async {
    try {
      final res = await _client.raw.request<dynamic>(
        '/v1/me/push-token',
        data: body,
        options: Options(method: method),
      );
      final data = res.data;
      if (data is Map) return Map<String, dynamic>.from(data);
      throw const PushFailure(PushFailureKind.malformed);
    } on DioException catch (e) {
      throw _failure(e);
    }
  }

  static PushFailure _failure(DioException e) {
    final status = e.response?.statusCode;
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.connectionError:
        return const PushFailure(PushFailureKind.network);
      default:
        break;
    }
    if (status == 401) return const PushFailure(PushFailureKind.unauthorized, statusCode: 401);
    if (status == 400) return const PushFailure(PushFailureKind.validation, statusCode: 400);
    return PushFailure(PushFailureKind.unknown, statusCode: status);
  }
}
