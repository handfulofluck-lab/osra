import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:familyshield_parent/api/client.dart';

/// Answers requests from a callback instead of a socket. Dio still runs its
/// interceptor chain, which is what these tests are about.
class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.respond);

  final ResponseBody Function(RequestOptions options) respond;
  final List<RequestOptions> calls = [];

  List<RequestOptions> callsTo(String path) =>
      [for (final call in calls) if (call.path == path) call];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls.add(options);
    return respond(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody jsonBody(int status, Object body) => ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({'jwt': 'old-token', 'refresh': 'refresh-1'});
  });

  ApiClient clientWith(_FakeAdapter adapter) {
    final client = ApiClient();
    client.raw.options.baseUrl = 'http://testserver';
    client.raw.httpClientAdapter = adapter;
    return client;
  }

  group('refresh exemption is per route, not the whole /v1/auth prefix', () {
    RequestOptions options(String path, {Object? data}) =>
        RequestOptions(path: path, method: 'POST', data: data);

    test('credential-only routes never refresh', () {
      for (final path in [
        '/v1/auth/login',
        '/v1/auth/register',
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
      ]) {
        expect(shouldRefreshOn401(options(path)), isFalse, reason: path);
      }
    });

    test('session-carrying routes refresh', () {
      for (final path in [
        '/v1/auth/mfa/reset/pending',
        '/v1/auth/mfa/reset/approve',
        '/v1/auth/mfa/recovery-codes',
        '/v1/auth/logout-all',
        '/v1/auth/mfa/enroll',
        '/v1/auth/mfa/verify',
        '/v1/family/me',
      ]) {
        expect(shouldRefreshOn401(options(path)), isTrue, reason: path);
      }
    });

    test('cancel is classified by its body: token = link, requestId = session', () {
      expect(
        shouldRefreshOn401(options('/v1/auth/mfa/reset/cancel', data: {'token': 'mailbox-token'})),
        isFalse,
      );
      expect(
        shouldRefreshOn401(options('/v1/auth/mfa/reset/cancel', data: {'requestId': 'req-1'})),
        isTrue,
      );
    });

    test('a purpose-scoped token is never swapped for the stored session', () {
      final request = RequestOptions(
        path: '/v1/auth/mfa/enroll',
        method: 'POST',
        extra: {'authToken': 'recovery-token'},
      );
      expect(shouldRefreshOn401(request), isFalse);
      final retried = RequestOptions(
        path: '/v1/family/me',
        method: 'GET',
        extra: {'retried': true},
      );
      expect(shouldRefreshOn401(retried), isFalse);
    });
  });

  group('behaviour through the interceptor', () {
    test('GET /mfa/reset/pending refreshes an expired session and retries', () async {
      final adapter = _FakeAdapter((options) {
        if (options.path == '/v1/auth/token/refresh') {
          return jsonBody(200, {'token': 'new-token', 'refreshToken': 'refresh-2'});
        }
        if (options.path == '/v1/auth/mfa/reset/pending') {
          return options.headers['Authorization'] == 'Bearer old-token'
              ? jsonBody(401, {'error': 'unauthorized'})
              : jsonBody(200, {'requests': <dynamic>[]});
        }
        return jsonBody(404, {'error': 'no_route'});
      });
      final client = clientWith(adapter);

      final res = await client.raw.get('/v1/auth/mfa/reset/pending');

      expect(res.statusCode, 200);
      expect(adapter.callsTo('/v1/auth/token/refresh'), hasLength(1));
      expect(adapter.callsTo('/v1/auth/mfa/reset/pending'), hasLength(2));
      expect(adapter.callsTo('/v1/auth/mfa/reset/pending').last.headers['Authorization'], 'Bearer new-token');
      expect(await const FlutterSecureStorage().read(key: 'jwt'), 'new-token');
    });

    test('the session form of /cancel refreshes, and keeps its body on the retry', () async {
      final adapter = _FakeAdapter((options) {
        if (options.path == '/v1/auth/token/refresh') {
          return jsonBody(200, {'token': 'new-token'});
        }
        if (options.path == '/v1/auth/mfa/reset/cancel') {
          return options.headers['Authorization'] == 'Bearer old-token'
              ? jsonBody(401, {'error': 'unauthorized'})
              : jsonBody(200, {'ok': true, 'state': 'cancelled_by_parent'});
        }
        return jsonBody(404, {'error': 'no_route'});
      });
      final client = clientWith(adapter);

      final res = await client.raw.post('/v1/auth/mfa/reset/cancel', data: {'requestId': 'req-1'});

      expect(res.statusCode, 200);
      expect(adapter.callsTo('/v1/auth/token/refresh'), hasLength(1));
      final retry = adapter.callsTo('/v1/auth/mfa/reset/cancel').last;
      expect(retry.headers['Authorization'], 'Bearer new-token');
      expect(retry.data, {'requestId': 'req-1'});
    });

    test('the link form of /cancel does not refresh', () async {
      final adapter = _FakeAdapter((options) {
        if (options.path == '/v1/auth/mfa/reset/cancel') {
          return jsonBody(401, {'error': 'invalid_or_expired_token'});
        }
        return jsonBody(200, {'token': 'should-not-be-used'});
      });
      final client = clientWith(adapter);

      await expectLater(
        client.raw.post('/v1/auth/mfa/reset/cancel', data: {'token': 'mailbox-token'}),
        throwsA(isA<DioException>()),
      );

      expect(adapter.callsTo('/v1/auth/token/refresh'), isEmpty);
      expect(adapter.callsTo('/v1/auth/mfa/reset/cancel'), hasLength(1));
    });

    test('POST /mfa/reset/status does not refresh: a wrong password is the answer', () async {
      final adapter = _FakeAdapter((options) {
        if (options.path == '/v1/auth/mfa/reset/status') {
          return jsonBody(401, {'error': 'invalid_credentials'});
        }
        return jsonBody(200, {'token': 'should-not-be-used'});
      });
      final client = clientWith(adapter);

      await expectLater(
        client.raw.post('/v1/auth/mfa/reset/status', data: {
          'email': 'qa@familyshield.dev',
          'password': 'wrong',
          'requestId': 'req-1',
        }),
        throwsA(isA<DioException>()),
      );

      expect(adapter.callsTo('/v1/auth/token/refresh'), isEmpty);
      expect(adapter.callsTo('/v1/auth/mfa/reset/status'), hasLength(1));
    });

    test('a purpose-scoped enrolment 401 is not retried with the stored session', () async {
      final adapter = _FakeAdapter((options) {
        if (options.path == '/v1/auth/mfa/enroll') {
          return jsonBody(401, {'error': 'invalid_or_expired_token'});
        }
        return jsonBody(200, {'token': 'should-not-be-used'});
      });
      final client = clientWith(adapter);

      await expectLater(
        client.raw.post(
          '/v1/auth/mfa/enroll',
          data: {'secret': 'X'},
          options: Options(extra: {'authToken': 'recovery-token'}),
        ),
        throwsA(isA<DioException>()),
      );

      expect(adapter.callsTo('/v1/auth/token/refresh'), isEmpty);
      expect(adapter.callsTo('/v1/auth/mfa/enroll'), hasLength(1));
    });
  });
}
