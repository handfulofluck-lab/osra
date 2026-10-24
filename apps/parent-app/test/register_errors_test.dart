import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:familyshield_parent/features/auth/auth_messages.dart';
import 'package:familyshield_parent/features/auth/login_screen.dart';
import 'package:familyshield_parent/l10n/l10n.dart';
import 'package:familyshield_parent/providers/auth_provider.dart';
import 'package:familyshield_parent/providers/onboarding_provider.dart';

import 'fake_api_client.dart';
import 'test_app.dart';

/// 3.2 first-run test (2026-10-23): a password under 12 characters made Register answer "Validation
/// failed", which named neither the field nor the rule. These rows pin the replacement: the rule is
/// shown up front, a short password or a missing name is caught before the request, and a server
/// rejection names its field beside the Register button.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({kOnboardingCompleteKey: true});
  });

  const validPassword = 'twelve-chars-ok';
  final en = lookupAppLocalizations(const Locale('en'));

  Finder fieldByLabel(String label) => find.ancestor(of: find.text(label), matching: find.byType(TextField));

  Future<void> pumpLogin(WidgetTester tester, FakeApiClient api, {Locale locale = const Locale('en')}) async {
    // Tall enough that the expanded register section needs no scrolling.
    tester.view.physicalSize = const Size(800, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(ProviderScope(
      overrides: [apiClientProvider.overrideWithValue(api)],
      child: localizedTestApp(const LoginScreen(), locale: locale),
    ));
    await tester.pumpAndSettle();
  }

  Future<void> fillRegister(
    WidgetTester tester, {
    String email = 'new@familyshield.dev',
    String password = validPassword,
    String familyName = 'Rivera',
    String displayName = 'Sam',
  }) async {
    await tester.enterText(fieldByLabel('Server'), 'http://testserver');
    await tester.enterText(fieldByLabel('Email'), email);
    await tester.enterText(fieldByLabel('Password'), password);
    await tester.tap(find.text('Create account'));
    await tester.pumpAndSettle();
    await tester.enterText(fieldByLabel('Family name'), familyName);
    await tester.enterText(fieldByLabel('Your name'), displayName);
  }

  Future<void> tapRegister(WidgetTester tester) async {
    await tester.tap(find.text('Register'));
    await tester.pumpAndSettle();
  }

  String? shown(WidgetTester tester, String key) {
    final f = find.byKey(ValueKey(key));
    return f.evaluate().isEmpty ? null : (tester.widget<Text>(f).data);
  }

  Map<String, FakeRoute> routesWithRegister(FakeRoute register) => {
        ...standardRoutes(),
        'POST /v1/auth/register': register,
      };

  group('register form', () {
    testWidgets('states the 12-character rule as soon as the section opens', (tester) async {
      await pumpLogin(tester, FakeApiClient(standardRoutes()));
      expect(find.byKey(const ValueKey('registerFieldsHint')), findsNothing);
      await tester.tap(find.text('Create account'));
      await tester.pumpAndSettle();
      expect(shown(tester, 'registerFieldsHint'), en.registerFieldsHint);
      expect(en.registerFieldsHint, contains('$kMinPasswordLength'));
    });

    testWidgets('a short password is named beside Register and never sent', (tester) async {
      final api = FakeApiClient(standardRoutes());
      await pumpLogin(tester, api);
      await fillRegister(tester, password: 'ten-chars!');
      await tapRegister(tester);

      expect(shown(tester, 'registerError'), en.registerPasswordTooShort);
      expect(find.byKey(const ValueKey('loginError')), findsNothing);
      expect(api.calls('POST', '/v1/auth/register'), isEmpty);
    });

    testWidgets('11 characters is still short and 12 is enough (the server minimum)', (tester) async {
      // The server answers 409 so a sent request stays on this screen: a success would navigate,
      // and this bare MaterialApp has no router.
      final api = FakeApiClient(routesWithRegister((_) => const FakeHttpError(409, {'error': 'email_taken'})));
      await pumpLogin(tester, api);
      await fillRegister(tester, password: 'a' * (kMinPasswordLength - 1));
      await tapRegister(tester);
      expect(shown(tester, 'registerError'), en.registerPasswordTooShort);
      expect(api.calls('POST', '/v1/auth/register'), isEmpty);

      await tester.enterText(fieldByLabel('Password'), 'a' * kMinPasswordLength);
      await tapRegister(tester);
      expect(api.calls('POST', '/v1/auth/register'), hasLength(1));
      expect(api.calls('POST', '/v1/auth/register').single.body['password'], 'a' * kMinPasswordLength);
    });

    testWidgets('a missing name is named before the request', (tester) async {
      final api = FakeApiClient(standardRoutes());
      await pumpLogin(tester, api);
      await fillRegister(tester, displayName: '   ');
      await tapRegister(tester);

      expect(shown(tester, 'registerError'), en.registerNamesRequired);
      expect(api.calls('POST', '/v1/auth/register'), isEmpty);
    });

    testWidgets('an email without @ is named before the request', (tester) async {
      final api = FakeApiClient(standardRoutes());
      await pumpLogin(tester, api);
      await fillRegister(tester, email: 'sam.example.com');
      await tapRegister(tester);

      expect(shown(tester, 'registerError'), en.authEmailInvalid);
      expect(api.calls('POST', '/v1/auth/register'), isEmpty);
    });

    testWidgets('a field the server rejects is named, never "Validation failed"', (tester) async {
      final api = FakeApiClient(routesWithRegister((_) => const FakeHttpError(400, {
            'error': {
              'formErrors': <String>[],
              'fieldErrors': {
                'email': ['Invalid email'],
              },
            },
          })));
      await pumpLogin(tester, api);
      // Has an @, so it passes the app's check; zod's stricter email check refuses it.
      await fillRegister(tester, email: 'sam@localhost');
      await tapRegister(tester);

      expect(api.calls('POST', '/v1/auth/register'), hasLength(1));
      expect(shown(tester, 'registerError'), en.authEmailInvalid);
      expect(find.text('Validation failed'), findsNothing);
      expect(find.textContaining(kValidationFailedPrefix), findsNothing);
    });

    testWidgets('a taken email says so and points to Sign in', (tester) async {
      final api = FakeApiClient(routesWithRegister((_) => const FakeHttpError(409, {'error': 'email_taken'})));
      await pumpLogin(tester, api);
      await fillRegister(tester);
      await tapRegister(tester);

      expect(shown(tester, 'registerError'), en.registerEmailTaken);
      expect(find.text('email_taken'), findsNothing);
    });

    testWidgets('pressing Sign in after a register error moves the message back above Sign in', (tester) async {
      final api = FakeApiClient(standardRoutes());
      await pumpLogin(tester, api);
      await fillRegister(tester, password: 'short');
      await tapRegister(tester);
      expect(shown(tester, 'registerError'), en.registerPasswordTooShort);

      await tester.enterText(fieldByLabel('Password'), 'wrong-password');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('registerError')), findsNothing);
      // The plain screen still shows the server's own string for a wrong password (unchanged).
      expect(shown(tester, 'loginError'), 'invalid_credentials');
    });

    testWidgets('Arabic: the rule and the short-password error are translated', (tester) async {
      final ar = lookupAppLocalizations(const Locale('ar'));
      final api = FakeApiClient(standardRoutes());
      await pumpLogin(tester, api, locale: const Locale('ar'));
      await tester.enterText(fieldByLabel(ar.serverLabel), 'http://testserver');
      await tester.enterText(fieldByLabel(ar.emailLabel), 'new@familyshield.dev');
      await tester.enterText(fieldByLabel(ar.passwordLabel), 'short');
      await tester.tap(find.text(ar.createAccount));
      await tester.pumpAndSettle();
      expect(shown(tester, 'registerFieldsHint'), ar.registerFieldsHint);

      await tester.tap(find.text(ar.register));
      await tester.pumpAndSettle();
      expect(shown(tester, 'registerError'), ar.registerPasswordTooShort);
      expect(ar.registerPasswordTooShort, isNot(en.registerPasswordTooShort));
    });
  });

  group('field-error mapping', () {
    test('the provider keeps the rejected field names, sorted', () async {
      final api = FakeApiClient({
        'POST /v1/auth/register': (_) => const FakeHttpError(400, {
              'error': {
                'formErrors': <String>[],
                'fieldErrors': {
                  'password': ['too short'],
                  'email': ['Invalid email'],
                },
              },
            }),
      });
      final notifier = AuthNotifier(api);
      addTearDown(notifier.dispose);
      await notifier.register(
          email: 'x@y', password: 'p', displayName: 'a', familyName: 'b', region: 'US');
      expect(notifier.state.error, '${kValidationFailedPrefix}email,password');
    });

    test('each field maps to its own sentence; anything else to the general one', () {
      expect(authFieldError(en, '${kValidationFailedPrefix}password'), en.registerPasswordTooShort);
      expect(authFieldError(en, '${kValidationFailedPrefix}familyName'), en.registerNamesRequired);
      expect(authFieldError(en, '${kValidationFailedPrefix}displayName'), en.registerNamesRequired);
      expect(authFieldError(en, '${kValidationFailedPrefix}email,password'), en.authEmailInvalid);
      expect(authFieldError(en, '${kValidationFailedPrefix}timezone'), en.authFieldsInvalid);
      expect(authFieldError(en, kValidationFailedPrefix), en.authFieldsInvalid);
    });
  });
}
