import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:familyshield_parent/api/models.dart';
import 'package:familyshield_parent/features/auth/login_screen.dart';
import 'package:familyshield_parent/features/auth/mfa_recovery_screen.dart';
import 'package:familyshield_parent/features/dashboard/dashboard_screen.dart';
import 'package:familyshield_parent/features/settings/mfa_enroll_screen.dart';
import 'package:familyshield_parent/features/settings/mfa_settings_screen.dart';
import 'package:familyshield_parent/features/settings/recovery_codes_screen.dart';
import 'package:familyshield_parent/providers/auth_provider.dart';
import 'package:familyshield_parent/providers/mfa_provider.dart';

import 'fake_api_client.dart';
import 'test_app.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  const secret = 'JBSWY3DPEHPK3PXP';
  const otpauthUrl =
      'otpauth://totp/OSRA:qa%40familyshield.dev?secret=JBSWY3DPEHPK3PXP&issuer=OSRA';

  const recoveryCodes = [
    'ABCD-EFGH-JKMN-PQRS',
    'BCDE-FGHJ-KMNP-QRST',
    'CDEF-GHJK-MNPQ-RSTV',
    'DEFG-HJKM-NPQR-STVW',
    'EFGH-JKMN-PQRS-TVWX',
    'FGHJ-KMNP-QRST-VWXY',
    'GHJK-MNPQ-RSTV-WXYZ',
    'HJKM-NPQR-STVW-XYZ1',
    'JKMN-PQRS-TVWX-YZ12',
    'KMNP-QRST-VWXY-Z123',
  ];

  RecoveryCodeBatch batch() =>
      RecoveryCodeBatch(codes: recoveryCodes, issuedAt: DateTime.utc(2026, 10, 19, 10));

  Map<String, dynamic> codesJson() => {
        'recoveryCodes': recoveryCodes,
        'recoveryCodesIssuedAt': '2026-10-19T10:00:00.000Z',
      };

  Map<String, FakeRoute> mfaRoutes({
    FakeRoute? enroll,
    FakeRoute? verify,
    FakeRoute? regenerate,
    FakeRoute? recover,
  }) =>
      {
        ...standardRoutes(),
        'POST /v1/auth/mfa/enroll':
            enroll ?? (_) => {'secret': secret, 'otpauthUrl': otpauthUrl},
        'POST /v1/auth/mfa/verify':
            verify ?? (_) => {'ok': true, 'mfaEnabled': true, ...codesJson()},
        'POST /v1/auth/mfa/recovery-codes': regenerate ?? (_) => codesJson(),
        'POST /v1/auth/mfa/recover': recover ?? (_) => {'recoveryToken': 'recovery-token'},
        'POST /v1/auth/logout': (_) => {'ok': true},
      };

  /// Lets a fake-Dio request chain complete: Dio dispatches through chained
  /// zero-duration Timers, which only fire when fake time advances.
  Future<void> flush(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> pumpScreen(
    WidgetTester tester,
    Widget home,
    FakeApiClient api, {
    Locale locale = const Locale('en'),
    TextDirection? direction,
    Size? size,
  }) async {
    if (size != null) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
    }
    await tester.pumpWidget(ProviderScope(
      overrides: [apiClientProvider.overrideWithValue(api)],
      child: localizedTestApp(home, locale: locale, textDirection: direction),
    ));
    await flush(tester);
  }

  List<Object> drainExceptions(WidgetTester tester) {
    final exceptions = <Object>[];
    while (true) {
      final e = tester.takeException();
      if (e == null) return exceptions;
      exceptions.add(e);
    }
  }

  void expectNoOverflow(WidgetTester tester) {
    final exceptions = drainExceptions(tester);
    expect(
      exceptions,
      isEmpty,
      reason: exceptions.map((e) => e is FlutterError ? e.toStringDeep() : '$e').join('\n'),
    );
  }

  group('MFA settings', () {
    testWidgets('shows the off state and the setup action', (tester) async {
      final api = FakeApiClient(mfaRoutes());
      await pumpScreen(tester, const MfaSettingsScreen(mfaEnabledOverride: false), api);

      expect(find.text('Two-step verification'), findsOneWidget);
      expect(find.text('Off'), findsOneWidget);
      expect(find.text('Set up authenticator'), findsOneWidget);
      expect(find.text('Generate new recovery codes'), findsOneWidget);
    });

    testWidgets('shows the on state and the replacement action', (tester) async {
      final api = FakeApiClient(mfaRoutes());
      await pumpScreen(tester, const MfaSettingsScreen(mfaEnabledOverride: true), api);

      expect(find.text('On'), findsOneWidget);
      expect(find.text('Replace authenticator'), findsOneWidget);
      expect(find.textContaining('replaces the old ones'), findsOneWidget);
    });

    testWidgets('the dashboard settings menu offers the MFA screen', (tester) async {
      final api = FakeApiClient(mfaRoutes());
      await pumpScreen(tester, const DashboardScreen(), api);
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      expect(find.text('Two-step verification'), findsOneWidget);
    });

    testWidgets('the login screen explains the sign-out after MFA was turned on', (tester) async {
      final api = FakeApiClient(mfaRoutes());
      final container = ProviderContainer(overrides: [apiClientProvider.overrideWithValue(api)]);
      addTearDown(container.dispose);
      container.read(loginNoticeProvider.notifier).state = kLoginNoticeMfaSessionEnded;

      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: localizedTestApp(const LoginScreen()),
      ));
      await flush(tester);

      expect(find.byKey(const ValueKey('loginMfaNotice')), findsOneWidget);
      expect(find.textContaining('Sign in again with your new authenticator'), findsOneWidget);
    });

    testWidgets('regeneration asks for the password and shows the new batch once', (tester) async {
      final api = FakeApiClient(mfaRoutes());
      await pumpScreen(tester, const MfaSettingsScreen(mfaEnabledOverride: true), api);

      await tester.tap(find.byKey(const ValueKey('mfaRegenerateButton')));
      await tester.pumpAndSettle();
      expect(find.text('Confirm it is you'), findsOneWidget);
      expect(api.calls('POST', '/v1/auth/mfa/recovery-codes'), isEmpty);

      await tester.enterText(find.byKey(const ValueKey('reauthPassword')), 'good-password');
      await tester.tap(find.byKey(const ValueKey('reauthConfirm')));
      await flush(tester);
      await tester.pumpAndSettle();

      final call = api.calls('POST', '/v1/auth/mfa/recovery-codes').single;
      expect(call.body['password'], 'good-password');
      expect(find.byType(RecoveryCodesScreen), findsOneWidget);
      expect(find.byKey(const ValueKey('recoveryCode0')), findsOneWidget);
      expect(find.byKey(const ValueKey('recoveryCode9')), findsOneWidget);
    });

    testWidgets('the re-auth dialog refuses an empty proof without calling the API', (tester) async {
      final api = FakeApiClient(mfaRoutes());
      await pumpScreen(tester, const MfaSettingsScreen(mfaEnabledOverride: true), api);

      await tester.tap(find.byKey(const ValueKey('mfaRegenerateButton')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('reauthConfirm')));
      await tester.pump();

      expect(find.byKey(const ValueKey('reauthError')), findsOneWidget);
      expect(find.text('Enter your password or a current authenticator code.'), findsNWidgets(2));
      expect(api.calls('POST', '/v1/auth/mfa/recovery-codes'), isEmpty);
    });

    testWidgets('a rejected re-auth is reported honestly and no batch appears', (tester) async {
      final api = FakeApiClient(mfaRoutes(
        regenerate: (_) => const FakeHttpError(401, {'error': 'reauth_required'}),
      ));
      await pumpScreen(tester, const MfaSettingsScreen(mfaEnabledOverride: true), api);

      await tester.tap(find.byKey(const ValueKey('mfaRegenerateButton')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('reauthPassword')), 'wrong-password');
      await tester.tap(find.byKey(const ValueKey('reauthConfirm')));
      await flush(tester);
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('mfaSettingsError')), findsOneWidget);
      expect(find.text('That password or code was not accepted.'), findsOneWidget);
      expect(find.byType(RecoveryCodesScreen), findsNothing);
    });

    testWidgets('a rate-limited regeneration says so', (tester) async {
      final api = FakeApiClient(mfaRoutes(
        regenerate: (_) => const FakeHttpError(429, {'error': 'rate_limited'}),
      ));
      await pumpScreen(tester, const MfaSettingsScreen(mfaEnabledOverride: true), api);

      await tester.tap(find.byKey(const ValueKey('mfaRegenerateButton')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('reauthPassword')), 'good-password');
      await tester.tap(find.byKey(const ValueKey('reauthConfirm')));
      await flush(tester);
      await tester.pumpAndSettle();

      expect(find.text('Too many attempts. Wait a minute and try again.'), findsOneWidget);
    });
  });

  group('MFA enrolment', () {
    testWidgets('shows the secret and QR, then the ten codes after verification', (tester) async {
      final api = FakeApiClient(mfaRoutes());
      await pumpScreen(tester, const MfaEnrollScreen(), api);

      expect(find.byKey(const ValueKey('mfaEnrollQr')), findsOneWidget);
      expect(find.text(secret), findsOneWidget);
      final qr = tester.widget<MfaQr>(find.byKey(const ValueKey('mfaEnrollQr')));
      expect(qr.data, otpauthUrl);

      await tester.enterText(find.byKey(const ValueKey('mfaEnrollCode')), '123456');
      await tester.tap(find.byKey(const ValueKey('mfaVerifyButton')));
      await flush(tester);
      await tester.pumpAndSettle();

      expect(find.byType(RecoveryCodesScreen), findsOneWidget);
      expect(find.byKey(const ValueKey('recoveryCode9')), findsOneWidget);
      expect(api.calls('POST', '/v1/auth/mfa/verify').single.body['code'], '123456');
    });

    testWidgets('an invalid code keeps the parent on the setup screen', (tester) async {
      final api = FakeApiClient(mfaRoutes(
        verify: (_) => const FakeHttpError(401, {'error': 'invalid_code'}),
      ));
      await pumpScreen(tester, const MfaEnrollScreen(), api);

      await tester.enterText(find.byKey(const ValueKey('mfaEnrollCode')), '123456');
      await tester.tap(find.byKey(const ValueKey('mfaVerifyButton')));
      await flush(tester);
      await tester.pumpAndSettle();

      expect(find.byType(RecoveryCodesScreen), findsNothing);
      expect(
        find.text('That code was not accepted. Check the clock on your phone and try the next code.'),
        findsOneWidget,
      );
    });

    testWidgets('a replacement secret asks for proof and retries with the password', (tester) async {
      final api = FakeApiClient(mfaRoutes(
        enroll: (req) => req.body['password'] == 'good-password'
            ? {'secret': secret, 'otpauthUrl': otpauthUrl}
            : const FakeHttpError(401, {'error': 'reauth_required'}),
      ));
      await pumpScreen(tester, const MfaEnrollScreen(), api);
      await tester.pumpAndSettle();

      expect(find.text('Confirm it is you'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('reauthPassword')), 'good-password');
      await tester.tap(find.byKey(const ValueKey('reauthConfirm')));
      await flush(tester);
      await tester.pumpAndSettle();

      final calls = api.calls('POST', '/v1/auth/mfa/enroll');
      expect(calls, hasLength(2));
      expect(calls.first.body['password'], isNull);
      expect(calls.last.body['password'], 'good-password');
      expect(find.byKey(const ValueKey('mfaEnrollQr')), findsOneWidget);
    });

    testWidgets('cancelling the proof prompt leaves an honest message, not a loop', (tester) async {
      final api = FakeApiClient(mfaRoutes(
        enroll: (_) => const FakeHttpError(401, {'error': 'reauth_required'}),
      ));
      await pumpScreen(tester, const MfaEnrollScreen(), api);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('mfaEnrollError')), findsOneWidget);
      expect(find.text('Enter your password or a current authenticator code.'), findsOneWidget);
      expect(api.calls('POST', '/v1/auth/mfa/enroll'), hasLength(1));
    });
  });

  group('Show-once recovery codes', () {
    testWidgets('lists ten codes, requires the saved confirmation, and copies all', (tester) async {
      final clipboard = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        clipboard.add(call);
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null));

      var exited = false;
      final api = FakeApiClient(mfaRoutes());
      await pumpScreen(
        tester,
        RecoveryCodesScreen(batch: batch(), onExit: () => exited = true),
        api,
        // Tall enough that the lazy ListView builds every control.
        size: const Size(400, 1200),
      );

      expect(find.byKey(const ValueKey('recoveryCode0')), findsOneWidget);
      expect(find.byKey(const ValueKey('recoveryCode9')), findsOneWidget);
      expect(
        tester.widget<FilledButton>(find.byKey(const ValueKey('recoveryCodesConfirm'))).onPressed,
        isNull,
      );

      await tester.tap(find.byKey(const ValueKey('recoveryCodesCopy')));
      await tester.pump();
      final copy = clipboard.where((c) => c.method == 'Clipboard.setData').single;
      expect((copy.arguments as Map)['text'], recoveryCodes.join('\n'));
      expect(find.text('Recovery codes copied'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('recoveryCodesSavedCheck')));
      await tester.pump();
      expect(
        tester.widget<FilledButton>(find.byKey(const ValueKey('recoveryCodesConfirm'))).onPressed,
        isNotNull,
      );

      await tester.tap(find.byKey(const ValueKey('recoveryCodesConfirm')));
      await tester.pump();
      expect(exited, isTrue);
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('back warns that the codes cannot be shown again', (tester) async {
      var exited = false;
      final api = FakeApiClient(mfaRoutes());
      await tester.pumpWidget(ProviderScope(
        overrides: [apiClientProvider.overrideWithValue(api)],
        child: localizedTestApp(Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => Navigator.of(context).push<void>(MaterialPageRoute(
                  builder: (_) => RecoveryCodesScreen(
                    batch: batch(),
                    onExit: () => exited = true,
                  ),
                )),
                child: const Text('open'),
              ),
            ),
          ),
        )),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text('Leave without saving?'), findsOneWidget);
      expect(find.textContaining('cannot be shown again'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('recoveryCodesStay')));
      await tester.pumpAndSettle();
      expect(find.byType(RecoveryCodesScreen), findsOneWidget);
      expect(exited, isFalse);

      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('recoveryCodesLeave')));
      await tester.pumpAndSettle();
      expect(exited, isTrue);
    });
  });

  group('Recovery path', () {
    testWidgets('the login screen offers "Lost your authenticator?"', (tester) async {
      final api = FakeApiClient(mfaRoutes());
      await pumpScreen(tester, const LoginScreen(), api);

      expect(find.text('Lost your authenticator?'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('lostAuthenticator')));
      await tester.pumpAndSettle();
      expect(find.byType(MfaRecoveryScreen), findsOneWidget);
      expect(find.text('Recover your account'), findsOneWidget);
    });

    testWidgets('email + password + code opens enrolment with the purpose-scoped token only', (tester) async {
      String? enrollAuth;
      final api = FakeApiClient(mfaRoutes(
        enroll: (req) {
          enrollAuth = req.headers['Authorization'] as String?;
          return {'secret': secret, 'otpauthUrl': otpauthUrl};
        },
      ));
      await pumpScreen(tester, const MfaRecoveryScreen(), api);

      await tester.enterText(find.byKey(const ValueKey('mfaRecoveryEmail')), 'qa@familyshield.dev');
      await tester.enterText(find.byKey(const ValueKey('mfaRecoveryPassword')), 'good-password');
      await tester.enterText(find.byKey(const ValueKey('mfaRecoveryCode')), recoveryCodes.first);
      await tester.tap(find.byKey(const ValueKey('mfaRecoverySubmit')));
      await flush(tester);
      await tester.pumpAndSettle();

      final recover = api.calls('POST', '/v1/auth/mfa/recover').single;
      expect(recover.body['email'], 'qa@familyshield.dev');
      expect(recover.body['code'], recoveryCodes.first);

      expect(find.byType(MfaEnrollScreen), findsOneWidget);
      expect(find.textContaining('Set up a new authenticator'), findsOneWidget);
      expect(enrollAuth, 'Bearer recovery-token');
      // The recovery token is not a session: nothing was written to the jwt slot.
      expect(await const FlutterSecureStorage().read(key: 'jwt'), isNull);
    });

    testWidgets('a rejected recovery shows the single generic message', (tester) async {
      final api = FakeApiClient(mfaRoutes(
        recover: (_) => const FakeHttpError(401, {'error': 'invalid_recovery'}),
      ));
      await pumpScreen(tester, const MfaRecoveryScreen(), api);

      await tester.enterText(find.byKey(const ValueKey('mfaRecoveryEmail')), 'nobody@example.com');
      await tester.enterText(find.byKey(const ValueKey('mfaRecoveryPassword')), 'wrong-password');
      await tester.enterText(find.byKey(const ValueKey('mfaRecoveryCode')), 'ZZZZ-ZZZZ-ZZZZ-ZZZZ');
      await tester.tap(find.byKey(const ValueKey('mfaRecoverySubmit')));
      await flush(tester);
      await tester.pumpAndSettle();

      expect(find.byType(MfaEnrollScreen), findsNothing);
      expect(find.text('The email, password or recovery code is incorrect.'), findsOneWidget);
      // No invented detail: the screen never says which field was wrong.
      expect(find.textContaining('email is not registered'), findsNothing);
    });

    testWidgets('an empty form is refused before any request', (tester) async {
      final api = FakeApiClient(mfaRoutes());
      await pumpScreen(tester, const MfaRecoveryScreen(), api);

      await tester.tap(find.byKey(const ValueKey('mfaRecoverySubmit')));
      await tester.pump();

      expect(find.text('Fill in email, password and recovery code.'), findsOneWidget);
      expect(api.calls('POST', '/v1/auth/mfa/recover'), isEmpty);
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('an expired recovery token is named, not retried as a session', (tester) async {
      final api = FakeApiClient(mfaRoutes(
        enroll: (_) => const FakeHttpError(401, {'error': 'unauthorized'}),
      ));
      await pumpScreen(tester, const MfaEnrollScreen(recoveryToken: 'expired'), api);

      expect(find.text('This recovery session has ended. Start recovery again.'), findsOneWidget);
      final call = api.calls('POST', '/v1/auth/mfa/enroll').single;
      expect(call.headers['Authorization'], 'Bearer expired');
    });
  });

  group('Arabic + RTL at 320x568 (no overflow)', () {
    Future<void> pumpArabic(WidgetTester tester, Widget home, FakeApiClient api) =>
        pumpScreen(
          tester,
          home,
          api,
          locale: const Locale('ar'),
          direction: TextDirection.rtl,
          size: const Size(320, 568),
        );

    void expectRtl(WidgetTester tester) {
      final scaffold = find.byType(Scaffold);
      expect(scaffold, findsWidgets);
      expect(Directionality.of(tester.element(scaffold.first)), TextDirection.rtl);
      expectNoOverflow(tester);
    }

    testWidgets('settings', (tester) async {
      await pumpArabic(
        tester,
        const MfaSettingsScreen(mfaEnabledOverride: true),
        FakeApiClient(mfaRoutes()),
      );
      expect(find.text('التحقق بخطوتين'), findsOneWidget);
      expectRtl(tester);
    });

    testWidgets('enrolment', (tester) async {
      await pumpArabic(tester, const MfaEnrollScreen(), FakeApiClient(mfaRoutes()));
      expect(find.text('إعداد التحقق بخطوتين'), findsOneWidget);
      expectRtl(tester);
    });

    testWidgets('recovery codes', (tester) async {
      await pumpArabic(
        tester,
        RecoveryCodesScreen(batch: batch()),
        FakeApiClient(mfaRoutes()),
      );
      expect(find.text('احفظ رموز الاسترداد'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('recoveryCodesSavedCheck')),
        160,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('لقد حفظت هذه الرموز'), findsWidgets);
      expectRtl(tester);
    });

    testWidgets('recovery form', (tester) async {
      await pumpArabic(tester, const MfaRecoveryScreen(), FakeApiClient(mfaRoutes()));
      expect(find.text('استرداد حسابك'), findsOneWidget);
      expectRtl(tester);
    });
  });

  group('MFA ARB key parity', () {
    Map<String, dynamic> readArb(String name) =>
        jsonDecode(File('lib/l10n/$name').readAsStringSync()) as Map<String, dynamic>;

    Set<String> mfaKeys(Map<String, dynamic> arb) =>
        {for (final k in arb.keys) if (k.startsWith('mfa') && !k.startsWith('@')) k};

    test('every MFA key exists, is non-empty and keeps its placeholders in Arabic', () {
      final en = readArb('app_en.arb');
      final ar = readArb('app_ar.arb');
      final keys = mfaKeys(en);
      expect(keys, isNotEmpty);
      expect(mfaKeys(ar), keys);

      final placeholder = RegExp(r'\{([A-Za-z][A-Za-z0-9_]*)[,}]');
      for (final key in keys) {
        expect((ar[key] as String?)?.trim(), isNotEmpty, reason: 'app_ar.arb is empty for $key');
        expect(
          {for (final m in placeholder.allMatches(ar[key] as String)) m.group(1)!},
          {for (final m in placeholder.allMatches(en[key] as String)) m.group(1)!},
          reason: 'placeholder mismatch for $key',
        );
      }
    });
  });
}
