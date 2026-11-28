import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:familyshield_parent/api/client.dart';
import 'package:familyshield_parent/api/permission_errors.dart';
import 'package:familyshield_parent/features/auth/login_screen.dart';
import 'package:familyshield_parent/l10n/app_localizations.dart';
import 'package:familyshield_parent/providers/auth_provider.dart';
import 'package:familyshield_parent/providers/onboarding_provider.dart';
import 'package:familyshield_parent/providers/server_provider.dart';

import 'fake_api_client.dart';
import 'test_app.dart';

/// Issue #763 unit & widget tests (with planted-fault mutants per AGENTS.md §3):
///   * M1 (no connectTimeout): removing `connectTimeout` from `ApiClient` -> breaks
///     `ApiClient configures explicit connect, receive, and send timeouts`.
///   * M2 (wrong Bureau copy): changing any EN/AR string or reverting to "the server"
///     -> breaks `Bureau-approved EN and AR strings match #763 rulings byte-for-byte`.
///   * M3 (leaking server hint into store build): showing `loginServerHintError` when
///     `showServerField` is false -> breaks `store build hides server-address hint`.
///   * M4 (silent stale session broken): setting `AuthState.error` on startup 401
///     -> breaks `stale stored session clears quietly on startup with no red error`.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final en = lookupAppLocalizations(const Locale('en'));
  final ar = lookupAppLocalizations(const Locale('ar'));

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({
      kOnboardingCompleteKey: true,
      kServerUrlKey: 'https://api.osratech.com',
    });
  });

  test('ApiClient configures explicit connect, receive, and send timeouts (#763 M1)', () {
    final client = ApiClient();
    expect(client.raw.options.connectTimeout, const Duration(seconds: 15));
    expect(client.raw.options.receiveTimeout, const Duration(seconds: 20));
    expect(client.raw.options.sendTimeout, const Duration(seconds: 15));
  });

  test('Bureau-approved EN and AR strings match #763 rulings byte-for-byte (#763 M2)', () {
    // Line 1: network (aligned across errorNoConnection, onboardingNoNetwork, mfaNetworkError)
    const enNet = "Can't reach OSRA. Check your internet connection and try again.";
    const arNet = 'تعذّر الاتصال بخدمة أسرة. تحقّق من اتصالك بالإنترنت ثم حاول مجددًا.';
    expect(en.errorNoConnection, enNet);
    expect(en.onboardingNoNetwork, enNet);
    expect(en.mfaNetworkError, enNet);
    expect(ar.errorNoConnection, arNet);
    expect(ar.onboardingNoNetwork, arNet);
    expect(ar.mfaNetworkError, arNet);

    // Line 2: debug-only server-field hint
    expect(en.errorCheckServerAddress, 'If you set a server address, check it too.');
    expect(ar.errorCheckServerAddress, 'إذا كنت قد أدخلت عنوان خادم، فتحقّق منه أيضًا.');

    // Line 3: 5xx
    expect(en.errorServerUnavailable, 'OSRA is not responding right now. Try again in a few minutes.');
    expect(ar.errorServerUnavailable, 'خدمة أسرة لا تستجيب الآن. حاول مجددًا بعد بضع دقائق.');

    // Line 4: 429
    expect(en.mfaTooManyAttempts, 'Too many attempts. Wait a minute and try again.');
    expect(ar.mfaTooManyAttempts, 'محاولات كثيرة جدًا. انتظر دقيقة ثم حاول مجددًا.');

    // Line 5: wrong credentials
    expect(en.onboardingWrongPassword, 'The email or password is incorrect. Check it and try again.');
    expect(ar.onboardingWrongPassword, 'البريد الإلكتروني أو كلمة المرور غير صحيحة. تحقق منها وحاول مجددًا.');

    // Line 6: anything else
    expect(en.errorSomethingWentWrong, 'Something went wrong. Try again.');
    expect(ar.errorSomethingWentWrong, 'حدث خطأ. حاول مجددًا.');
  });

  testWidgets('debug login shows approved network line + server hint, keeps fields filled, and hides raw Dio text',
      (tester) async {
    final api = FakeApiClient({
      ...standardRoutes(),
      'POST /v1/auth/login': (req) => throw DioException(
            requestOptions: RequestOptions(path: req.path),
            type: DioExceptionType.connectionTimeout,
            message: 'The request connection took longer than 0:00:00.000000. SocketException',
          ),
    });
    await tester.pumpWidget(ProviderScope(
      overrides: [apiClientProvider.overrideWithValue(api)],
      child: localizedTestApp(const LoginScreen(debug: true, builtIn: '')),
    ));
    await tester.pumpAndSettle();

    Finder field(String label) => find.ancestor(of: find.text(label), matching: find.byType(TextField));
    await tester.enterText(field('Server'), 'http://testserver');
    await tester.enterText(field('Email'), 'parent@osratech.com');
    await tester.enterText(field('Password'), 'twelve-chars-ok');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('loginErrorIcon')), findsOneWidget);
    expect(tester.widget<Text>(find.byKey(const ValueKey('loginError'))).data, en.onboardingNoNetwork);
    expect(tester.widget<Text>(find.byKey(const ValueKey('loginServerHintError'))).data, en.errorCheckServerAddress);
    expect(find.textContaining('0:00:00'), findsNothing);
    expect(find.textContaining('SocketException'), findsNothing);
    expect(find.textContaining('DioException'), findsNothing);
    // Email and password stay filled for immediate retry.
    expect(tester.widget<TextField>(field('Email')).controller?.text, 'parent@osratech.com');
    expect(tester.widget<TextField>(field('Password')).controller?.text, 'twelve-chars-ok');
  });

  testWidgets('store build hides server-address hint on network error (#763 M3)', (tester) async {
    final api = FakeApiClient({
      ...standardRoutes(),
      'POST /v1/auth/login': (req) => throw DioException(
            requestOptions: RequestOptions(path: req.path),
            type: DioExceptionType.connectionError,
            message: 'Failed host lookup',
          ),
    });
    await tester.pumpWidget(ProviderScope(
      overrides: [apiClientProvider.overrideWithValue(api)],
      child: localizedTestApp(const LoginScreen(debug: false, builtIn: 'https://api.osratech.com')),
    ));
    await tester.pumpAndSettle();

    Finder field(String label) => find.ancestor(of: find.text(label), matching: find.byType(TextField));
    await tester.enterText(field('Email'), 'parent@osratech.com');
    await tester.enterText(field('Password'), 'twelve-chars-ok');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();

    expect(tester.widget<Text>(find.byKey(const ValueKey('loginError'))).data, en.onboardingNoNetwork);
    expect(find.byKey(const ValueKey('loginServerHintError')), findsNothing);
  });

  testWidgets('login maps 5xx and 429 to approved Arabic Bureau lines', (tester) async {
    for (final (status, expected) in [
      (503, ar.errorServerUnavailable),
      (429, ar.mfaTooManyAttempts),
    ]) {
      final api = FakeApiClient({
        ...standardRoutes(),
        'POST /v1/auth/login': (_) => FakeHttpError(status, {'error': 'err_$status'}),
      });
      await tester.pumpWidget(ProviderScope(
        overrides: [apiClientProvider.overrideWithValue(api)],
        child: localizedTestApp(
          const LoginScreen(debug: false, builtIn: 'https://api.osratech.com'),
          locale: const Locale('ar'),
          textDirection: TextDirection.rtl,
        ),
      ));
      await tester.pumpAndSettle();

      Finder field(String label) => find.ancestor(of: find.text(label), matching: find.byType(TextField));
      await tester.enterText(field(ar.emailLabel), 'parent@osratech.com');
      await tester.enterText(field(ar.passwordLabel), 'twelve-chars-ok');
      await tester.tap(find.text(ar.signIn));
      await tester.pumpAndSettle();

      expect(tester.widget<Text>(find.byKey(const ValueKey('loginError'))).data, expected);
    }
  });

  testWidgets('stale stored session clears quietly on startup with no red error (#763 M4)', (tester) async {
    FlutterSecureStorage.setMockInitialValues({'jwt': 'expired-jwt', 'refresh': 'expired-refresh'});
    final api = FakeApiClient({
      ...standardRoutes(),
      'GET /v1/family/me': (_) => const FakeHttpError(401, {'error': 'unauthorized'}),
    });
    await tester.pumpWidget(ProviderScope(
      overrides: [apiClientProvider.overrideWithValue(api)],
      child: localizedTestApp(const LoginScreen(debug: false, builtIn: 'https://api.osratech.com')),
    ));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('loginError')), findsNothing);
    expect(find.textContaining('unauthorized'), findsNothing);
    expect(find.text(en.onboardingWrongPassword), findsNothing);
    expect(await const FlutterSecureStorage().read(key: 'jwt'), isNull);
    expect(await const FlutterSecureStorage().read(key: 'refresh'), isNull);
  });

  test('friendlyErrorText maps 429 and network to approved lines and keeps fallback on 5xx', () {
    final opts = RequestOptions(path: '/v1/alerts');
    DioException http(int code) => DioException(
          requestOptions: opts,
          response: Response(requestOptions: opts, statusCode: code, data: {'error': 'x'}),
          type: DioExceptionType.badResponse,
        );
    expect(friendlyErrorText(en, http(429), () => 'fallback'), en.mfaTooManyAttempts);
    expect(friendlyErrorText(ar, http(429), () => 'fallback'), ar.mfaTooManyAttempts);
    expect(friendlyErrorText(en, http(502), () => 'fallback'), 'fallback');
    expect(friendlyErrorText(ar, http(503), () => 'fallback'), 'fallback');
  });
}
