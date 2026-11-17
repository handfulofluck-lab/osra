import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:familyshield_parent/api/permission_errors.dart';
import 'package:familyshield_parent/features/alerts/alerts_screen.dart';
import 'package:familyshield_parent/features/auth/login_screen.dart';
import 'package:familyshield_parent/features/settings/digest_prefs_screen.dart';
import 'package:familyshield_parent/features/settings/timezone_catalog.dart';
import 'package:familyshield_parent/l10n/app_localizations.dart';
import 'package:familyshield_parent/providers/auth_provider.dart';
import 'package:familyshield_parent/providers/onboarding_provider.dart';

import 'fake_api_client.dart';
import 'test_app.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final en = lookupAppLocalizations(const Locale('en'));

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({kOnboardingCompleteKey: true});
  });

  group('R-ID-1 ARB & friendly error mapping', () {
    test('no locale ARB file keeps an {error} or {detail} placeholder', () {
      for (final file in ['lib/l10n/app_en.arb', 'lib/l10n/app_ar.arb']) {
        final raw = File(file).readAsStringSync();
        final map = jsonDecode(raw) as Map<String, dynamic>;
        for (final entry in map.entries) {
          if (entry.value is! String) continue;
          final v = entry.value as String;
          expect(v, isNot(contains('{error}')), reason: '$file ${entry.key}');
          expect(v, isNot(contains('{detail}')), reason: '$file ${entry.key}');
        }
      }
    });

    test('friendlyErrorText maps permission, consent, network, and 5xx cleanly', () {
      final opts = RequestOptions(path: '/v1/test');
      DioException http(int status, Map<String, dynamic> body) => DioException(
            requestOptions: opts,
            response: Response(requestOptions: opts, statusCode: status, data: body),
            type: DioExceptionType.badResponse,
          );

      expect(
        friendlyErrorText(en, http(403, {'error': 'permission_required', 'permission': 'alerts'}), () => 'fallback'),
        en.readPermissionRequired,
      );
      expect(
        friendlyErrorText(en, http(428, {'error': 'parental_consent_required'}), () => 'fallback'),
        en.readErrorConsentMissing,
      );
      expect(
        friendlyErrorText(en, DioException(requestOptions: opts, type: DioExceptionType.connectionTimeout), () => 'fallback'),
        en.errorNoConnection,
      );
      expect(
        friendlyErrorText(en, http(500, {'error': 'boom'}), () => en.alertsLoadFailed),
        en.alertsLoadFailed,
      );
      expect(friendlyErrorText(en, StateError('secret stack trace'), () => en.familyLoadFailed), en.familyLoadFailed);
    });

    testWidgets('alerts screen failure hides DioException/HTTP codes and offers Retry', (tester) async {
      final api = FakeApiClient({
        ...standardRoutes(),
        'GET /v1/alerts': (_) => const FakeHttpError(500, {'error': 'db_timeout'}),
      });
      await tester.pumpWidget(ProviderScope(
        overrides: [apiClientProvider.overrideWithValue(api)],
        child: localizedTestApp(const AlertsScreen()),
      ));
      await tester.pumpAndSettle();

      expect(find.text(en.alertsLoadFailed), findsOneWidget);
      expect(find.text(en.retry), findsOneWidget);
      expect(find.textContaining('500'), findsNothing);
      expect(find.textContaining('db_timeout'), findsNothing);
      expect(find.textContaining('DioException'), findsNothing);
    });

    testWidgets('login screen hides raw exception text on unexpected auth response', (tester) async {
      final api = FakeApiClient({
        ...standardRoutes(),
        // Missing token triggers FormatException inside AuthNotifier._authenticate
        'POST /v1/auth/login': (_) => const {'unexpected': true},
      });
      await tester.pumpWidget(ProviderScope(
        overrides: [apiClientProvider.overrideWithValue(api)],
        child: localizedTestApp(const LoginScreen()),
      ));
      await tester.pumpAndSettle();

      Finder field(String label) => find.ancestor(of: find.text(label), matching: find.byType(TextField));
      await tester.enterText(field('Server'), 'http://testserver');
      await tester.enterText(field('Email'), 'parent@osratech.com');
      await tester.enterText(field('Password'), 'twelve-chars-ok');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('loginError')), findsOneWidget);
      expect(find.textContaining('FormatException'), findsNothing);
      expect(find.textContaining('auth response missing token'), findsNothing);
      expect(find.text(en.authSignInFailed), findsOneWidget);
    });

    testWidgets('plain sign-in translates invalid_credentials to onboardingWrongPassword', (tester) async {
      final api = FakeApiClient({
        ...standardRoutes(),
        'POST /v1/auth/login': (_) => const FakeHttpError(401, {'error': 'invalid_credentials'}),
      });
      await tester.pumpWidget(ProviderScope(
        overrides: [apiClientProvider.overrideWithValue(api)],
        child: localizedTestApp(const LoginScreen()),
      ));
      await tester.pumpAndSettle();

      Finder field(String label) => find.ancestor(of: find.text(label), matching: find.byType(TextField));
      await tester.enterText(field('Server'), 'http://testserver');
      await tester.enterText(field('Email'), 'parent@osratech.com');
      await tester.enterText(field('Password'), 'twelve-chars-ok');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();

      expect(find.descendant(of: find.byKey(const ValueKey('loginError')), matching: find.text(en.onboardingWrongPassword)), findsOneWidget);
      expect(find.textContaining('invalid_credentials'), findsNothing);
    });
  });

  group('R-ID-3 searchable city/GMT timezone picker', () {
    test('timezone catalog formats city + GMT, defaults by device offset, orders current first', () {
      expect(formatTimezoneLabel('Asia/Dubai'), 'Dubai (GMT+4)');
      expect(formatTimezoneLabel('America/Argentina/Buenos_Aires'), 'Buenos Aires (GMT-3)');
      expect(defaultDeviceTimezone(const Duration(hours: 4)), 'Asia/Dubai');
      final ordered = orderedTimezones('Asia/Riyadh');
      expect(ordered.first.id, 'Asia/Riyadh');
      expect(ordered.where((o) => o.id == 'Asia/Riyadh'), hasLength(1));
    });

    testWidgets('picker pins current zone first, filters search, works in 320px RTL without overflow', (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final api = FakeApiClient({
        ...standardRoutes(),
        'GET /v1/digests/prefs': (_) => {
              'dailyEmail': false,
              'weeklyEmail': false,
              'pushEnabled': true,
              'emails': <String>[],
            },
        'GET /v1/family/me': (_) => {
              'family': {'id': 'fam-1', 'name': 'Demo', 'region': 'US', 'timezone': 'Asia/Riyadh', 'children': []},
            },
        'PATCH /v1/family/me': (req) => {
              'family': {'id': 'fam-1', 'timezone': req.body['timezone']},
            },
      });
      await tester.pumpWidget(ProviderScope(
        overrides: [apiClientProvider.overrideWithValue(api)],
        child: localizedTestApp(const DigestPrefsScreen(), locale: const Locale('ar'), textDirection: TextDirection.rtl),
      ));
      await tester.pumpAndSettle();

      expect(find.text('Riyadh (GMT+3)'), findsOneWidget);
      expect(find.text('Asia/Riyadh'), findsNothing);

      await tester.drag(find.byType(ListView), const Offset(0, -350));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const ValueKey('digestTimezone')));
      await tester.tap(find.byKey(const ValueKey('digestTimezone')));
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(const ValueKey('digestTimezoneSearch')), '+4');
      await tester.pumpAndSettle();
      expect(find.descendant(of: find.byType(BottomSheet), matching: find.text('Dubai (GMT+4)')), findsOneWidget);
      expect(find.descendant(of: find.byType(BottomSheet), matching: find.text('Riyadh (GMT+3)')), findsNothing);

      await tester.tap(find.descendant(of: find.byType(BottomSheet), matching: find.text('Dubai (GMT+4)')));
      await tester.pumpAndSettle();
      expect(api.calls('PATCH', '/v1/family/me').single.body['timezone'], 'Asia/Dubai');
      expect(tester.takeException(), isNull);
    });
  });
}
