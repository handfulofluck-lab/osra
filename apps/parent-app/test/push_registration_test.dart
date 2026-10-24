import 'package:flutter/foundation.dart' show TargetPlatform;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:familyshield_parent/api/push_api.dart';
import 'package:familyshield_parent/providers/auth_provider.dart';
import 'package:familyshield_parent/push/push_registration.dart';

import 'fake_api_client.dart';

/// A token source that answers with whatever the case under test needs, so the
/// seam is exercised without a push plugin (there is none in this repository).
class _FakeTokenSource implements PushTokenSource {
  _FakeTokenSource({this.permission = PushPermission.granted, this.value = 'apns-token-0123456789abcdef'});

  final PushPermission permission;
  final String? value;
  int permissionCalls = 0;
  int tokenCalls = 0;

  @override
  Future<PushPermission> requestPermission() async {
    permissionCalls += 1;
    return permission;
  }

  @override
  Future<String?> token() async {
    tokenCalls += 1;
    return value;
  }
}

Map<String, FakeRoute> _routes({
  Object? registerResponse = const {'id': 'push-1', 'platform': 'ios', 'registeredAt': '2026-10-24T00:00:00Z'},
  Object? removeResponse = const {'removed': 1},
}) =>
    {
      'POST /v1/me/push-token': (_) => registerResponse,
      'DELETE /v1/me/push-token': (_) => removeResponse,
    };

void main() {
  group('the iOS registration rides the existing route', () {
    test('an APNs token is forwarded to POST /v1/me/push-token as platform "ios"', () async {
      final api = FakeApiClient(_routes());
      final registration = PushRegistration(
        api: PushApi(api),
        source: _FakeTokenSource(),
        platform: PushPlatform.ios,
        appVersion: '0.1.0',
      );

      expect(await registration.register(), PushRegistrationOutcome.registered);

      final sent = api.calls('POST', '/v1/me/push-token');
      expect(sent, hasLength(1));
      expect(sent.single.body, {
        'token': 'apns-token-0123456789abcdef',
        'platform': 'ios',
        'appVersion': '0.1.0',
      });
    });

    test('the wire value is the string the route\'s enum accepts', () {
      // Mutant: renaming PushPlatform.ios's wire value to "iOS" or "apple"
      // turns the server's z.enum into a 400 and this fails.
      expect(PushPlatform.ios.wire, 'ios');
    });

    test('an unknown platform mapping would send android, never web, for a mobile target', () {
      expect(pushPlatformFor(TargetPlatform.iOS), PushPlatform.ios);
      expect(pushPlatformFor(TargetPlatform.android), PushPlatform.android);
      // A desktop target is not `web`: the server routes `web` to the FCM
      // provider, which cannot deliver an APNs token.
      expect(pushPlatformFor(TargetPlatform.macOS), isNot(PushPlatform.web));
    });
  });

  group('nothing is sent that the OS did not grant', () {
    test('a refused prompt sends no request', () async {
      final api = FakeApiClient(_routes());
      final source = _FakeTokenSource(permission: PushPermission.denied);
      final registration = PushRegistration(api: PushApi(api), source: source, platform: PushPlatform.ios);

      expect(await registration.register(), PushRegistrationOutcome.denied);
      expect(api.requests, isEmpty);
      // A refusal must not even ask the SDK for a token.
      expect(source.tokenCalls, 0);
    });

    test('the shipped default source reports unavailable and sends nothing', () async {
      final api = FakeApiClient(_routes());
      // No `source:` — this is the object the app actually constructs today.
      final registration = PushRegistration(api: PushApi(api));

      expect(await registration.register(), PushRegistrationOutcome.unavailable);
      // Mutant: drop the `unavailable` short-circuit in register() and this
      // records one POST with a null token that the route would reject.
      expect(api.requests, isEmpty);
    });

    test('granted permission with no token yet mints nothing and sends nothing', () async {
      final api = FakeApiClient(_routes());
      final registration = PushRegistration(
        api: PushApi(api),
        source: _FakeTokenSource(value: null),
        platform: PushPlatform.ios,
      );

      expect(await registration.register(), PushRegistrationOutcome.noToken);
      expect(api.requests, isEmpty);
    });
  });

  group('a failure is reported, never thrown', () {
    test('a 401 from the route is PushRegistrationOutcome.failed', () async {
      final api = FakeApiClient(_routes(registerResponse: const FakeHttpError(401, {'error': 'unauthorized'})));
      final registration = PushRegistration(api: PushApi(api), source: _FakeTokenSource(), platform: PushPlatform.ios);

      expect(await registration.register(), PushRegistrationOutcome.failed);
    });

    test('an unreachable server is PushRegistrationOutcome.failed', () async {
      final api = FakeApiClient(_routes(registerResponse: const FakeNetworkError()));
      final registration = PushRegistration(api: PushApi(api), source: _FakeTokenSource(), platform: PushPlatform.ios);

      expect(await registration.register(), PushRegistrationOutcome.failed);
    });

    test('a rejected registration is not remembered, so logout removes nothing', () async {
      final api = FakeApiClient(_routes(registerResponse: const FakeHttpError(400, {'error': 'validation'})));
      final registration = PushRegistration(api: PushApi(api), source: _FakeTokenSource(), platform: PushPlatform.ios);

      expect(await registration.register(), PushRegistrationOutcome.failed);
      expect(registration.registeredToken, isNull);
      expect(await registration.unregister(), isFalse);
      expect(api.calls('DELETE', '/v1/me/push-token'), isEmpty);
    });
  });

  group('logout removes the row it created', () {
    test('unregister deletes the token this instance registered', () async {
      final api = FakeApiClient(_routes());
      final registration = PushRegistration(api: PushApi(api), source: _FakeTokenSource(), platform: PushPlatform.ios);

      await registration.register();
      expect(await registration.unregister(), isTrue);

      final sent = api.calls('DELETE', '/v1/me/push-token');
      expect(sent, hasLength(1));
      expect(sent.single.body, {'token': 'apns-token-0123456789abcdef'});
      expect(registration.registeredToken, isNull);
    });

    test('unregister before any registration sends no request', () async {
      final api = FakeApiClient(_routes());
      final registration = PushRegistration(api: PushApi(api), source: _FakeTokenSource(), platform: PushPlatform.ios);

      expect(await registration.unregister(), isFalse);
      expect(api.requests, isEmpty);
    });
  });

  group('logout removes the row before the session is revoked', () {
    test('DELETE /v1/me/push-token is recorded before POST /v1/auth/logout', () async {
      FlutterSecureStorage.setMockInitialValues({'jwt': 'jwt-token', 'refresh': 'refresh-token'});
      final api = FakeApiClient({
        ..._routes(),
        'POST /v1/auth/logout': (_) => const {'ok': true},
      });
      final registration = PushRegistration(api: PushApi(api), source: _FakeTokenSource(), platform: PushPlatform.ios);
      expect(await registration.register(), PushRegistrationOutcome.registered);
      api.requests.clear();

      final notifier = AuthNotifier(api, push: registration);
      await notifier.logout();

      final paths = [for (final r in api.requests) '${r.method} ${r.path}'];
      expect(paths, contains('DELETE /v1/me/push-token'));
      expect(paths, contains('POST /v1/auth/logout'));
      // The order is the assertion. `/v1/auth/logout` revokes the access token
      // issued with this refresh token (`services/api/src/routes/auth.ts:1442`),
      // so a DELETE issued after it carries a dead JWT, answers 401, and
      // `unregister()`'s catch leaves the row waking a phone someone signed out.
      // Mutant: move the push block below the logout call in AuthNotifier.logout()
      // and this index comparison is the test that goes red.
      expect(
        paths.indexOf('DELETE /v1/me/push-token'),
        lessThan(paths.indexOf('POST /v1/auth/logout')),
        reason: 'the push token must be removed while its JWT is still valid: $paths',
      );
      notifier.dispose();
    });
  });

  group('PushApi reduces the route\'s answers to a typed failure', () {
    test('a 400 is validation', () async {
      final api = FakeApiClient(_routes(registerResponse: const FakeHttpError(400, {'error': 'validation'})));
      expect(
        () => PushApi(api).register(token: 'short', platform: PushPlatform.ios),
        throwsA(isA<PushFailure>().having((f) => f.kind, 'kind', PushFailureKind.validation)),
      );
    });

    test('a 2xx without an id is malformed, not a success', () async {
      final api = FakeApiClient(_routes(registerResponse: const {'ok': true}));
      expect(
        () => PushApi(api).register(token: 'apns-token-0123456789abcdef', platform: PushPlatform.ios),
        throwsA(isA<PushFailure>().having((f) => f.kind, 'kind', PushFailureKind.malformed)),
      );
    });

    test('remove reports the count the route returned', () async {
      final api = FakeApiClient(_routes(removeResponse: const {'removed': 0}));
      expect(await PushApi(api).remove('apns-token-0123456789abcdef'), 0);
    });
  });
}
