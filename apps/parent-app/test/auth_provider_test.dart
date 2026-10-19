import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:familyshield_parent/api/client.dart';
import 'package:familyshield_parent/providers/auth_provider.dart';

/// Canned GET /v1/family/me payload.
const _familyMe = {
  'family': {'id': 'fam-1', 'name': 'Demo Family', 'region': 'US', 'createdAt': '2026-09-14T00:00:00Z'},
  'parent': {
    'id': 'par-1',
    'familyId': 'fam-1',
    'email': 'demo@familyshield.dev',
    'displayName': 'Demo Parent',
    'role': 'owner',
    'mfaEnabled': false,
  },
  'children': [
    {'id': 'child-1', 'familyId': 'fam-1', 'displayName': 'Alex', 'birthYear': 2013, 'screenTimeTodayMinutes': 45},
  ],
  'devices': [
    {
      'id': 'dev-1',
      'childId': 'child-1',
      'platform': 'android',
      'model': 'Pixel 7a',
      'osVersion': '14',
      'status': 'online',
      'batteryPct': 80,
      'lastSeen': '2026-09-14T10:00:00Z',
    },
  ],
};

/// Network-free [ApiClient]: `raw` returns a Dio whose interceptor resolves
/// canned JSON (login with password 'good-password' → token + refreshToken;
/// 'mfa-password' → 401 mfa_required; /v1/family/me → [_familyMe]; anything
/// else → 401). Records the last login body in [loginBody].
class FakeApiClient extends ApiClient {
  Map<String, dynamic>? loginBody;

  @override
  Dio get raw {
    final dio = Dio(BaseOptions(baseUrl: 'http://testserver'));
    dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
      if (options.path == '/v1/auth/login') {
        loginBody = Map<String, dynamic>.from((options.data as Map?) ?? const {});
        final password = loginBody!['password'];
        if (password == 'good-password') {
          handler.resolve(Response(requestOptions: options, data: {'token': 'jwt-token', 'refreshToken': 'refresh-token'}));
        } else if (password == 'mfa-password') {
          handler.reject(DioException(
            requestOptions: options,
            response: Response(requestOptions: options, statusCode: 401, data: {'error': 'mfa_required'}),
            type: DioExceptionType.badResponse,
          ));
        } else if (password == 'reenroll-password') {
          // #183: a recovered account whose new authenticator was never verified.
          handler.reject(DioException(
            requestOptions: options,
            response: Response(requestOptions: options, statusCode: 401, data: {'error': 'mfa_reenroll_required'}),
            type: DioExceptionType.badResponse,
          ));
        } else {
          handler.reject(DioException(
            requestOptions: options,
            response: Response(requestOptions: options, statusCode: 401, data: {'error': 'invalid_credentials'}),
            type: DioExceptionType.badResponse,
          ));
        }
      } else if (options.path == '/v1/family/me') {
        handler.resolve(Response(requestOptions: options, data: _familyMe));
      } else {
        handler.reject(DioException(
          requestOptions: options,
          response: Response(requestOptions: options, statusCode: 401, data: {'error': 'invalid_credentials'}),
          type: DioExceptionType.badResponse,
        ));
      }
    }));
    return dio;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ProviderContainer container;
  late FakeApiClient api;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    // In-memory shared_preferences so ServerUrlNotifier.load() resolves fast.
    SharedPreferences.setMockInitialValues({});
    api = FakeApiClient();
    container = ProviderContainer(overrides: [apiClientProvider.overrideWithValue(api)]);
  });

  tearDown(() => container.dispose());

  /// Waits for the authProvider factory's fire-and-forget bootstrap() to finish.
  Future<void> settle() async {
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
  }

  test('initial state is logged out', () async {
    await settle();
    final state = container.read(authProvider);
    expect(state.isAuthenticated, isFalse);
    expect(state.parent, isNull);
    expect(state.error, isNull);
  });

  test('successful login sets isAuthenticated and loads family', () async {
    await container.read(authProvider.notifier).login('demo@familyshield.dev', 'good-password');
    final state = container.read(authProvider);
    expect(state.isAuthenticated, isTrue);
    expect(state.loading, isFalse);
    expect(state.parent?.email, 'demo@familyshield.dev');
    expect(state.family?.name, 'Demo Family');
    expect(state.family?.region, 'US');
  });

  test('failed login (401) sets error and stays logged out', () async {
    await container.read(authProvider.notifier).login('demo@familyshield.dev', 'wrong-password');
    final state = container.read(authProvider);
    expect(state.isAuthenticated, isFalse);
    expect(state.error, 'invalid_credentials');
  });

  test('successful login stores the refresh token for 401 retries', () async {
    await container.read(authProvider.notifier).login('demo@familyshield.dev', 'good-password');
    expect(container.read(authProvider).isAuthenticated, isTrue);
    final refresh = await const FlutterSecureStorage().read(key: 'refresh');
    expect(refresh, 'refresh-token');
  });

  test('login sends the MFA code only when non-empty', () async {
    await container.read(authProvider.notifier).login('demo@familyshield.dev', 'good-password');
    expect(api.loginBody, isNotNull);
    expect(api.loginBody!.containsKey('code'), isFalse);

    await container.read(authProvider.notifier).login('demo@familyshield.dev', 'good-password', ' 123456 ');
    expect(api.loginBody!['code'], '123456');
  });

  test('401 with an mfa error shows Invalid authentication code', () async {
    await container.read(authProvider.notifier).login('demo@familyshield.dev', 'mfa-password');
    final state = container.read(authProvider);
    expect(state.isAuthenticated, isFalse);
    expect(state.error, 'Invalid authentication code');
  });

  test('#183: mfa_reenroll_required is reported as a missing authenticator, not a wrong code', () async {
    await container.read(authProvider.notifier).login('demo@familyshield.dev', 'reenroll-password');
    final state = container.read(authProvider);
    expect(state.isAuthenticated, isFalse);
    expect(state.error, isNot('Invalid authentication code'));
    expect(state.error, contains('no authenticator is set up'));
  });

  test('logout returns to the logged-out state', () async {
    final notifier = container.read(authProvider.notifier);
    await notifier.login('demo@familyshield.dev', 'good-password');
    expect(container.read(authProvider).isAuthenticated, isTrue);
    await notifier.logout();
    final state = container.read(authProvider);
    expect(state.isAuthenticated, isFalse);
    expect(state.parent, isNull);
    expect(state.family, isNull);
  });

  test('bootstrap with a stored token restores the session', () async {
    FlutterSecureStorage.setMockInitialValues({'jwt': 'stored-token'});
    final fresh = ProviderContainer(overrides: [apiClientProvider.overrideWithValue(FakeApiClient())]);
    addTearDown(fresh.dispose);
    // Reading the notifier triggers the provider factory (which kicks off
    // bootstrap()); then let the async storage-read + HTTP round-trip settle.
    fresh.read(authProvider.notifier);
    for (var i = 0; i < 4; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    final state = fresh.read(authProvider);
    expect(state.isAuthenticated, isTrue);
    expect(state.parent?.displayName, 'Demo Parent');
  });
}
