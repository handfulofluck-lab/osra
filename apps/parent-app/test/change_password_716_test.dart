import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:familyshield_parent/features/settings/change_password_screen.dart';
import 'package:familyshield_parent/l10n/app_localizations.dart';
import 'package:familyshield_parent/providers/auth_provider.dart';
import 'package:familyshield_parent/theme/app_theme.dart';

import 'fake_api_client.dart';

/// #716: change the password while signed in. The screen sends the current and new password (and a code
/// when two-step sign-in is on), stores the fresh token pair the server returns, and turns every refusal
/// into a sentence.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({'jwt': 'old-jwt', 'refresh': 'old-refresh'});
    SharedPreferences.setMockInitialValues({});
  });

  FakeApiClient api({bool mfa = false, FakeRoute? onChange}) {
    final me = familyMeTwoChildren();
    (me['parent'] as Map<String, dynamic>)['mfaEnabled'] = mfa;
    return FakeApiClient({
      ...standardRoutes(familyMe: me),
      'POST /v1/auth/password': onChange ?? (_) => {'ok': true, 'token': 'new-jwt', 'refreshToken': 'new-refresh'},
    });
  }

  Future<void> pump(
    WidgetTester tester,
    FakeApiClient client, {
    Locale locale = const Locale('en'),
    Size size = const Size(390, 1600),
    double textScale = 1,
    bool dark = false,
  }) async {
    tester.view.physicalSize = size * 3;
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: [apiClientProvider.overrideWithValue(client)],
      child: MaterialApp(
        locale: locale,
        theme: dark ? AppTheme.dark : AppTheme.light,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, inner) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
          child: inner!,
        ),
        home: const ChangePasswordScreen(),
      ),
    ));
    await tester.pumpAndSettle();
  }

  Future<void> fill(WidgetTester tester, {String current = 'old-password-1', String next = 'brand-new-password', String? again, String? code}) async {
    await tester.enterText(find.byKey(const ValueKey('cpCurrent')), current);
    await tester.enterText(find.byKey(const ValueKey('cpNew')), next);
    await tester.enterText(find.byKey(const ValueKey('cpAgain')), again ?? next);
    if (code != null) await tester.enterText(find.byKey(const ValueKey('cpCode')), code);
    await tester.pump();
  }

  Future<void> submit(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('cpSubmit')));
    await tester.pumpAndSettle();
  }

  FilledButton button(WidgetTester tester) => tester.widget<FilledButton>(find.byKey(const ValueKey('cpSubmit')));

  testWidgets('C1 sends both passwords and stores the fresh token pair', (tester) async {
    final client = api();
    await pump(tester, client);
    expect(find.byKey(const ValueKey('cpCode')), findsNothing, reason: 'no code field without two-step sign-in');
    await fill(tester);
    await submit(tester);

    final calls = client.calls('POST', '/v1/auth/password');
    expect(calls, hasLength(1));
    expect(calls.single.body['currentPassword'], 'old-password-1');
    expect(calls.single.body['newPassword'], 'brand-new-password');
    expect(calls.single.body.containsKey('code'), isFalse);
    const storage = FlutterSecureStorage();
    expect(await storage.read(key: 'jwt'), 'new-jwt');
    expect(await storage.read(key: 'refresh'), 'new-refresh');
    expect(find.byKey(const ValueKey('cpError')), findsNothing);
  });

  testWidgets('C2 the button stays off until the new password has 12 characters', (tester) async {
    await pump(tester, api());
    expect(button(tester).onPressed, isNull);
    await fill(tester, next: 'short-pass1');
    expect(button(tester).onPressed, isNull);
    await fill(tester, next: 'long-enough-1');
    expect(button(tester).onPressed, isNotNull);
  });

  testWidgets('C3 a mismatch is caught on the phone and nothing is sent', (tester) async {
    final client = api();
    await pump(tester, client);
    await fill(tester, again: 'something-else-1');
    await submit(tester);
    expect(find.text("The two new passwords don't match."), findsOneWidget);
    expect(client.calls('POST', '/v1/auth/password'), isEmpty);
  });

  testWidgets('C4 a wrong current password reads as a sentence and the old session is kept', (tester) async {
    final client = api(onChange: (_) => const FakeHttpError(401, {'error': 'invalid_credentials'}));
    await pump(tester, client);
    await fill(tester);
    await submit(tester);
    expect(find.text("Your current password isn't right."), findsOneWidget);
    // No refresh-and-replay of a wrong password, and the stored session is untouched.
    expect(client.calls('POST', '/v1/auth/password'), hasLength(1));
    expect(client.calls('POST', '/v1/auth/token/refresh'), isEmpty);
    expect(await const FlutterSecureStorage().read(key: 'jwt'), 'old-jwt');
  });

  testWidgets('C5 with two-step sign-in on, a code is required and sent', (tester) async {
    final client = api(mfa: true);
    await pump(tester, client);
    expect(find.byKey(const ValueKey('cpCode')), findsOneWidget);
    await fill(tester);
    expect(button(tester).onPressed, isNull, reason: 'the code is still empty');
    await fill(tester, code: ' 123456 ');
    await submit(tester);
    expect(client.calls('POST', '/v1/auth/password').single.body['code'], '123456');
  });

  for (final (status, body, text) in [
    (401, {'error': 'mfa_required'}, 'Enter a current code from your authenticator app, or an unused recovery code.'),
    (400, {'error': 'password_unchanged'}, "Choose a password that's different from your current one."),
    (429, {'error': 'rate_limited'}, 'Too many tries. Wait a few minutes, then try again.'),
  ]) {
    testWidgets('C6 a $status ${body['error']} refusal reads as a sentence', (tester) async {
      await pump(tester, api(onChange: (_) => FakeHttpError(status, body)));
      await fill(tester);
      await submit(tester);
      expect(find.text(text), findsOneWidget);
    });
  }

  for (final dark in [false, true]) {
    for (final locale in const [Locale('en'), Locale('ar')]) {
      testWidgets('C7 320 px at 200% text fits (${locale.languageCode}, ${dark ? 'dark' : 'light'})', (tester) async {
        await pump(tester, api(mfa: true), locale: locale, size: const Size(320, 3000), textScale: 2, dark: dark);
        expect(tester.takeException(), isNull);
        final size = tester.getSize(find.byKey(const ValueKey('cpSubmit')));
        expect(size.height, greaterThanOrEqualTo(48));
        if (locale.languageCode == 'ar') {
          expect(find.text('تغيير كلمة المرور'), findsWidgets);
          expect(Directionality.of(tester.element(find.byKey(const ValueKey('cpIntro')))), TextDirection.rtl);
        }
      });
    }
  }
}
