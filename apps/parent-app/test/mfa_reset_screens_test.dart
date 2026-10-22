import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:familyshield_parent/features/auth/mfa_recovery_screen.dart';
import 'package:familyshield_parent/features/auth/mfa_reset_approval_screen.dart';
import 'package:familyshield_parent/features/auth/mfa_reset_request_screen.dart';
import 'package:familyshield_parent/features/auth/mfa_reset_waiting_screen.dart';
import 'package:familyshield_parent/features/auth/mfa_reset_witness_screen.dart';
import 'package:familyshield_parent/features/settings/mfa_enroll_screen.dart';
import 'package:familyshield_parent/features/settings/mfa_settings_screen.dart';
import 'package:familyshield_parent/providers/auth_provider.dart';

import 'fake_api_client.dart';
import 'test_app.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  final windowEnd = DateTime.now().toUtc().add(const Duration(hours: 72));
  final windowPast = DateTime.now().toUtc().subtract(const Duration(minutes: 5));

  Map<String, dynamic> accepted() => {
        'ok': true,
        'state': 'witness_passed',
        'windowEndsAt': windowEnd.toIso8601String(),
      };

  Map<String, FakeRoute> resetRoutes({
    FakeRoute? request,
    FakeRoute? witness,
    FakeRoute? approve,
    FakeRoute? cancel,
    FakeRoute? complete,
  }) =>
      {
        ...standardRoutes(),
        'POST /v1/auth/mfa/reset/request':
            request ?? (_) => {
                  'ok': true,
                  'requestId': 'req-1',
                  'expiresAt': DateTime.now().toUtc().add(const Duration(minutes: 30)).toIso8601String(),
                },
        'POST /v1/auth/mfa/reset/confirm': (_) => {
              'ok': true,
              'requestId': 'req-1',
              'witness': 'device',
              'codeExpiresAt': DateTime.now().toUtc().add(const Duration(minutes: 10)).toIso8601String(),
            },
        'POST /v1/auth/mfa/reset/witness': witness ?? (_) => accepted(),
        'POST /v1/auth/mfa/reset/approve': approve ?? (_) => accepted(),
        'POST /v1/auth/mfa/reset/cancel': cancel ?? (_) => {'ok': true, 'state': 'cancelled_by_parent'},
        'POST /v1/auth/mfa/reset/complete': complete ?? (_) => {'recoveryToken': 'recovery-token'},
        'POST /v1/auth/mfa/enroll': (_) => {
              'secret': 'JBSWY3DPEHPK3PXP',
              'otpauthUrl': 'otpauth://totp/OSRA:qa%40familyshield.dev?secret=JBSWY3DPEHPK3PXP&issuer=OSRA',
            },
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

  MfaResetProgress mailboxStage() => MfaResetProgress(
        requestId: 'req-1',
        stage: MfaResetStage.awaitingMailbox,
        email: 'qa@familyshield.dev',
        mailboxExpiresAt: DateTime.now().add(const Duration(minutes: 30)),
      );

  group('Reset request (ADR-0031 decision 2.1-2.2)', () {
    testWidgets('states the three factors and asks only for email and password', (tester) async {
      final api = FakeApiClient(resetRoutes());
      await pumpScreen(tester, const MfaResetRequestScreen(), api);

      expect(find.text('Reset two-step verification'), findsOneWidget);
      expect(find.textContaining('a code shown on your child\'s phone'), findsOneWidget);
      expect(find.textContaining('72-hour wait'), findsOneWidget);

      await tester.enterText(find.byKey(const ValueKey('mfaResetEmail')), 'qa@familyshield.dev');
      await tester.enterText(find.byKey(const ValueKey('mfaResetPassword')), 'good-password');
      await tester.tap(find.byKey(const ValueKey('mfaResetSubmit')));
      await flush(tester);
      await tester.pumpAndSettle();

      final call = api.calls('POST', '/v1/auth/mfa/reset/request').single;
      expect(call.body['email'], 'qa@familyshield.dev');
      expect(call.body['password'], 'good-password');
      expect(find.byType(MfaResetWaitingScreen), findsOneWidget);
      expect(find.text('Check your email'), findsOneWidget);
    });

    testWidgets('an empty form is refused before any request', (tester) async {
      final api = FakeApiClient(resetRoutes());
      await pumpScreen(tester, const MfaResetRequestScreen(), api);

      await tester.tap(find.byKey(const ValueKey('mfaResetSubmit')));
      await tester.pump();

      expect(find.text('Fill in your email and password.'), findsOneWidget);
      expect(api.calls('POST', '/v1/auth/mfa/reset/request'), isEmpty);
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('a wrong password keeps the same refusal as /login, naming no field', (tester) async {
      final api = FakeApiClient(resetRoutes(
        request: (_) => const FakeHttpError(401, {'error': 'invalid_credentials'}),
      ));
      await pumpScreen(tester, const MfaResetRequestScreen(), api);

      await tester.enterText(find.byKey(const ValueKey('mfaResetEmail')), 'qa@familyshield.dev');
      await tester.enterText(find.byKey(const ValueKey('mfaResetPassword')), 'wrong-password');
      await tester.tap(find.byKey(const ValueKey('mfaResetSubmit')));
      await flush(tester);
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('mfaResetError')), findsOneWidget);
      expect(find.text('The email or password is incorrect.'), findsOneWidget);
      expect(find.textContaining('email is not registered'), findsNothing);
      expect(find.byType(MfaResetWaitingScreen), findsNothing);
    });

    testWidgets('no_witness is explained plainly and nothing is opened', (tester) async {
      final api = FakeApiClient(resetRoutes(
        request: (_) => const FakeHttpError(409, {'error': 'no_witness'}),
      ));
      await pumpScreen(tester, const MfaResetRequestScreen(), api);

      await tester.enterText(find.byKey(const ValueKey('mfaResetEmail')), 'qa@familyshield.dev');
      await tester.enterText(find.byKey(const ValueKey('mfaResetPassword')), 'good-password');
      await tester.tap(find.byKey(const ValueKey('mfaResetSubmit')));
      await flush(tester);
      await tester.pumpAndSettle();

      expect(find.textContaining('no family witness'), findsOneWidget);
      expect(find.textContaining('create a new account with another email address'), findsOneWidget);
    });

    testWidgets('a request already in its 72-hour window is named as such', (tester) async {
      final api = FakeApiClient(resetRoutes(
        request: (_) => const FakeHttpError(409, {'error': 'reset_already_pending'}),
      ));
      await pumpScreen(tester, const MfaResetRequestScreen(), api);

      await tester.enterText(find.byKey(const ValueKey('mfaResetEmail')), 'qa@familyshield.dev');
      await tester.enterText(find.byKey(const ValueKey('mfaResetPassword')), 'good-password');
      await tester.tap(find.byKey(const ValueKey('mfaResetSubmit')));
      await flush(tester);
      await tester.pumpAndSettle();

      expect(find.textContaining('already in its 72-hour wait'), findsOneWidget);
    });

    testWidgets('the 30-day ceiling gets its own message', (tester) async {
      final api = FakeApiClient(resetRoutes(
        request: (_) => const FakeHttpError(429, {'error': 'reset_limit_reached'}),
      ));
      await pumpScreen(tester, const MfaResetRequestScreen(), api);

      await tester.enterText(find.byKey(const ValueKey('mfaResetEmail')), 'qa@familyshield.dev');
      await tester.enterText(find.byKey(const ValueKey('mfaResetPassword')), 'good-password');
      await tester.tap(find.byKey(const ValueKey('mfaResetSubmit')));
      await flush(tester);
      await tester.pumpAndSettle();

      expect(find.textContaining('three resets in 30 days'), findsOneWidget);
      // Not the generic rate-limit sentence.
      expect(find.text('Too many attempts. Wait a minute and try again.'), findsNothing);
    });

    testWidgets('a network failure says so instead of blaming the credentials', (tester) async {
      final api = FakeApiClient(resetRoutes(request: (_) => const FakeNetworkError()));
      await pumpScreen(tester, const MfaResetRequestScreen(), api);

      await tester.enterText(find.byKey(const ValueKey('mfaResetEmail')), 'qa@familyshield.dev');
      await tester.enterText(find.byKey(const ValueKey('mfaResetPassword')), 'good-password');
      await tester.tap(find.byKey(const ValueKey('mfaResetSubmit')));
      await flush(tester);
      await tester.pumpAndSettle();

      expect(find.text('Could not reach the server. Check your connection and try again.'), findsOneWidget);
    });
  });

  group('Waiting state (ADR-0031 decisions 2.4, 3)', () {
    testWidgets('shows the mailbox stage, the deadline and the next action', (tester) async {
      final api = FakeApiClient(resetRoutes());
      await pumpScreen(tester, MfaResetWaitingScreen(progress: mailboxStage()), api);

      expect(find.text('Reset in progress'), findsOneWidget);
      expect(find.text('Check your email'), findsOneWidget);
      expect(find.textContaining('within 30 minutes'), findsOneWidget);
      expect(find.byKey(const ValueKey('mfaResetDeadline')), findsOneWidget);
      expect(find.byKey(const ValueKey('mfaResetHaveCode')), findsOneWidget);
      expect(find.byKey(const ValueKey('mfaResetCancel')), findsOneWidget);
    });

    testWidgets('entering the child code moves the screen into the 72-hour window', (tester) async {
      final api = FakeApiClient(resetRoutes());
      await pumpScreen(tester, MfaResetWaitingScreen(progress: mailboxStage()), api);

      await tester.tap(find.byKey(const ValueKey('mfaResetHaveCode')));
      await tester.pumpAndSettle();
      expect(find.byType(MfaResetWitnessScreen), findsOneWidget);

      await tester.enterText(find.byKey(const ValueKey('mfaResetWitnessCode')), '12345678');
      await tester.tap(find.byKey(const ValueKey('mfaResetWitnessSubmit')));
      await flush(tester);
      await tester.pumpAndSettle();

      expect(find.byType(MfaResetWitnessScreen), findsNothing);
      expect(find.text('The 72-hour wait has started'), findsOneWidget);
      expect(find.textContaining('The wait ends at'), findsOneWidget);
      expect(api.calls('POST', '/v1/auth/mfa/reset/witness').single.body['requestId'], 'req-1');
    });

    testWidgets('cancel confirms, posts the request id and reports the outcome', (tester) async {
      final api = FakeApiClient(resetRoutes());
      await pumpScreen(tester, MfaResetWaitingScreen(progress: mailboxStage()), api);

      await tester.tap(find.byKey(const ValueKey('mfaResetCancel')));
      await tester.pumpAndSettle();
      expect(find.text('Cancel this request?'), findsOneWidget);
      expect(api.calls('POST', '/v1/auth/mfa/reset/cancel'), isEmpty);

      await tester.tap(find.byKey(const ValueKey('mfaResetCancelConfirm')));
      await flush(tester);
      await tester.pumpAndSettle();

      final call = api.calls('POST', '/v1/auth/mfa/reset/cancel').single;
      expect(call.body['requestId'], 'req-1');
      expect(call.body['token'], isNull);
      expect(find.byKey(const ValueKey('mfaResetCancelled')), findsOneWidget);
    });

    testWidgets('keeping the dialog open cancels nothing', (tester) async {
      final api = FakeApiClient(resetRoutes());
      await pumpScreen(tester, MfaResetWaitingScreen(progress: mailboxStage()), api);

      await tester.tap(find.byKey(const ValueKey('mfaResetCancel')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('mfaResetCancelKeep')));
      await tester.pumpAndSettle();

      expect(api.calls('POST', '/v1/auth/mfa/reset/cancel'), isEmpty);
      expect(find.byKey(const ValueKey('mfaResetCancelled')), findsNothing);
    });

    testWidgets('a forbidden cancel points at the emailed link instead of pretending', (tester) async {
      final api = FakeApiClient(resetRoutes(
        cancel: (_) => const FakeHttpError(403, {'error': 'forbidden'}),
      ));
      await pumpScreen(tester, MfaResetWaitingScreen(progress: mailboxStage()), api);

      await tester.tap(find.byKey(const ValueKey('mfaResetCancel')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('mfaResetCancelConfirm')));
      await flush(tester);
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('mfaResetWaitingError')), findsOneWidget);
      expect(find.textContaining('Only another owner or co-parent can cancel from the app'), findsOneWidget);
      expect(find.byKey(const ValueKey('mfaResetCancelled')), findsNothing);
    });

    testWidgets('before windowEndsAt there is no finish action', (tester) async {
      final api = FakeApiClient(resetRoutes());
      await pumpScreen(
        tester,
        MfaResetWaitingScreen(
          progress: MfaResetProgress(
            requestId: 'req-1',
            stage: MfaResetStage.window,
            email: 'qa@familyshield.dev',
            windowEndsAt: DateTime.now().add(const Duration(hours: 10)),
          ),
        ),
        api,
      );

      expect(find.byKey(const ValueKey('mfaResetFinish')), findsNothing);
      expect(find.textContaining('The wait ends at'), findsOneWidget);
    });

    testWidgets('after the window, complete produces the recovery token and re-enrolment', (tester) async {
      final api = FakeApiClient(resetRoutes());
      await pumpScreen(
        tester,
        MfaResetWaitingScreen(
          progress: MfaResetProgress(
            requestId: 'req-1',
            stage: MfaResetStage.window,
            email: 'qa@familyshield.dev',
            windowEndsAt: windowPast,
          ),
        ),
        api,
      );

      expect(find.byKey(const ValueKey('mfaResetFinish')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('mfaResetFinish')));
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(const ValueKey('mfaResetFinishEmail')), 'qa@familyshield.dev');
      await tester.enterText(find.byKey(const ValueKey('mfaResetFinishPassword')), 'good-password');
      await tester.tap(find.byKey(const ValueKey('mfaResetFinishSubmit')));
      await flush(tester);
      await tester.pumpAndSettle();

      final complete = api.calls('POST', '/v1/auth/mfa/reset/complete').single;
      expect(complete.body['requestId'], 'req-1');
      expect(complete.body['email'], 'qa@familyshield.dev');
      expect(find.byType(MfaEnrollScreen), findsOneWidget);
      // The purpose-scoped token is used for enrolment, never stored as a session.
      final enroll = api.calls('POST', '/v1/auth/mfa/enroll').single;
      expect(enroll.headers['Authorization'], 'Bearer recovery-token');
      expect(await const FlutterSecureStorage().read(key: 'jwt'), isNull);
    });

    testWidgets('a complete before the window is refused and changes nothing', (tester) async {
      final api = FakeApiClient(resetRoutes(
        complete: (_) => const FakeHttpError(409, {'error': 'window_open'}),
      ));
      await pumpScreen(
        tester,
        MfaResetWaitingScreen(
          progress: MfaResetProgress(
            requestId: 'req-1',
            stage: MfaResetStage.window,
            email: 'qa@familyshield.dev',
            windowEndsAt: windowPast,
          ),
        ),
        api,
      );

      await tester.tap(find.byKey(const ValueKey('mfaResetFinish')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('mfaResetFinishPassword')), 'good-password');
      await tester.tap(find.byKey(const ValueKey('mfaResetFinishSubmit')));
      await flush(tester);
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('mfaResetFinishError')), findsOneWidget);
      expect(find.text('The wait is not over yet. Nothing has changed.'), findsOneWidget);
      expect(find.byType(MfaEnrollScreen), findsNothing);
    });
  });

  group('Witness code (ADR-0031 decision 2.3)', () {
    testWidgets('a code that is not 8 digits is refused before the API', (tester) async {
      final api = FakeApiClient(resetRoutes());
      await pumpScreen(tester, const MfaResetWitnessScreen(requestId: 'req-1'), api);

      await tester.enterText(find.byKey(const ValueKey('mfaResetWitnessCode')), '123');
      await tester.tap(find.byKey(const ValueKey('mfaResetWitnessSubmit')));
      await tester.pump();

      expect(find.text('Enter the 8-digit code.'), findsOneWidget);
      expect(api.calls('POST', '/v1/auth/mfa/reset/witness'), isEmpty);
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('the field keeps digits only and stops at eight', (tester) async {
      final api = FakeApiClient(resetRoutes());
      await pumpScreen(tester, const MfaResetWitnessScreen(requestId: 'req-1'), api);

      await tester.enterText(find.byKey(const ValueKey('mfaResetWitnessCode')), '1a2b34567890');
      final field = tester.widget<TextField>(find.byKey(const ValueKey('mfaResetWitnessCode')));
      expect(field.controller!.text, '12345678');
      expect(field.keyboardType, TextInputType.number);
    });

    testWidgets('a wrong code shows the server attempts left, still naming no cause', (tester) async {
      final api = FakeApiClient(resetRoutes(
        witness: (_) => const FakeHttpError(401, {'error': 'invalid_witness', 'attemptsRemaining': 4}),
      ));
      await pumpScreen(tester, const MfaResetWitnessScreen(requestId: 'req-1'), api);

      await tester.enterText(find.byKey(const ValueKey('mfaResetWitnessCode')), '00000000');
      await tester.tap(find.byKey(const ValueKey('mfaResetWitnessSubmit')));
      await flush(tester);
      await tester.pumpAndSettle();

      expect(find.text('That code was not accepted. Attempts left: 4.'), findsOneWidget);
    });

    testWidgets('an expired or unknown code falls back to the single generic message', (tester) async {
      final api = FakeApiClient(resetRoutes(
        witness: (_) => const FakeHttpError(401, {'error': 'invalid_witness'}),
      ));
      await pumpScreen(tester, const MfaResetWitnessScreen(requestId: 'req-1'), api);

      await tester.enterText(find.byKey(const ValueKey('mfaResetWitnessCode')), '00000000');
      await tester.tap(find.byKey(const ValueKey('mfaResetWitnessSubmit')));
      await flush(tester);
      await tester.pumpAndSettle();

      expect(find.text('That code was not accepted or has expired. Check the code on your child\'s phone and try again.'),
          findsOneWidget);
      expect(find.textContaining('Attempts left'), findsNothing);
    });

    testWidgets('the fifth wrong code ends the request and disables retrying', (tester) async {
      final api = FakeApiClient(resetRoutes(
        witness: (_) => const FakeHttpError(401, {'error': 'too_many_attempts'}),
      ));
      await pumpScreen(tester, const MfaResetWitnessScreen(requestId: 'req-1'), api);

      await tester.enterText(find.byKey(const ValueKey('mfaResetWitnessCode')), '00000000');
      await tester.tap(find.byKey(const ValueKey('mfaResetWitnessSubmit')));
      await flush(tester);
      await tester.pumpAndSettle();

      expect(find.textContaining('Too many wrong codes'), findsOneWidget);
      expect(
        tester.widget<FilledButton>(find.byKey(const ValueKey('mfaResetWitnessSubmit'))).onPressed,
        isNull,
      );
    });
  });

  group('Co-parent approval (ADR-0031 decision 2.3, claim 4)', () {
    testWidgets('approve posts the request id and reports the window', (tester) async {
      final api = FakeApiClient(resetRoutes());
      await pumpScreen(tester, const MfaResetApprovalScreen(requestId: 'req-1'), api);

      expect(find.text('Approve a reset request'), findsOneWidget);
      expect(find.textContaining('72-hour wait'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('mfaResetApprove')));
      await flush(tester);
      await tester.pumpAndSettle();

      expect(api.calls('POST', '/v1/auth/mfa/reset/approve').single.body['requestId'], 'req-1');
      expect(find.byKey(const ValueKey('mfaResetApproved')), findsOneWidget);
      expect(find.byKey(const ValueKey('mfaResetApprove')), findsNothing);
    });

    testWidgets('decline confirms and cancels the request', (tester) async {
      final api = FakeApiClient(resetRoutes());
      await pumpScreen(tester, const MfaResetApprovalScreen(requestId: 'req-1'), api);

      await tester.tap(find.byKey(const ValueKey('mfaResetDecline')));
      await tester.pumpAndSettle();
      expect(find.text('Decline this request?'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('mfaResetDeclineConfirm')));
      await flush(tester);
      await tester.pumpAndSettle();

      expect(api.calls('POST', '/v1/auth/mfa/reset/cancel').single.body['requestId'], 'req-1');
      expect(find.byKey(const ValueKey('mfaResetDeclined')), findsOneWidget);
      expect(api.calls('POST', '/v1/auth/mfa/reset/approve'), isEmpty);
    });

    testWidgets('a guardian is refused in words, matching the API role rule', (tester) async {
      final api = FakeApiClient(resetRoutes(
        approve: (_) => const FakeHttpError(403, {'error': 'role_not_allowed'}),
      ));
      await pumpScreen(tester, const MfaResetApprovalScreen(requestId: 'req-1'), api);

      await tester.tap(find.byKey(const ValueKey('mfaResetApprove')));
      await flush(tester);
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('mfaResetApproveError')), findsOneWidget);
      expect(find.text('Only an owner or co-parent can approve or decline a reset request.'), findsOneWidget);
    });

    testWidgets('an empty request id is not a blank approve/decline prompt', (tester) async {
      final api = FakeApiClient(resetRoutes());
      await pumpScreen(tester, const MfaResetApprovalScreen(requestId: ''), api);

      expect(find.byKey(const ValueKey('mfaResetApproveMissingId')), findsOneWidget);
      expect(find.byKey(const ValueKey('mfaResetApprove')), findsNothing);
      expect(find.byKey(const ValueKey('mfaResetDecline')), findsNothing);
    });
  });

  group('Entries into the reset flow', () {
    testWidgets('the lost-authenticator recovery screen offers the no-code path', (tester) async {
      final api = FakeApiClient(resetRoutes());
      await pumpScreen(tester, const MfaRecoveryScreen(), api);

      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('mfaResetEntry')),
        160,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.byKey(const ValueKey('mfaResetEntry')));
      await tester.pumpAndSettle();

      expect(find.byType(MfaResetRequestScreen), findsOneWidget);
      expect(find.text('Reset two-step verification'), findsOneWidget);
    });

    testWidgets('settings offers the reset route beside the recovery codes', (tester) async {
      final api = FakeApiClient(resetRoutes());
      await pumpScreen(tester, const MfaSettingsScreen(mfaEnabledOverride: true), api);

      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('mfaResetEntry')),
        160,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.byKey(const ValueKey('mfaResetEntry')));
      await tester.pumpAndSettle();

      expect(find.byType(MfaResetRequestScreen), findsOneWidget);
    });
  });

  group('Arabic + RTL at 320x568 (no overflow)', () {
    Future<void> pumpArabic(WidgetTester tester, Widget home, FakeApiClient api) => pumpScreen(
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

    testWidgets('request', (tester) async {
      await pumpArabic(tester, const MfaResetRequestScreen(), FakeApiClient(resetRoutes()));
      expect(find.text('إعادة تعيين التحقق بخطوتين'), findsOneWidget);
      expect(find.text('اطلب إعادة التعيين'), findsOneWidget);
      expectRtl(tester);
    });

    testWidgets('waiting', (tester) async {
      await pumpArabic(
        tester,
        MfaResetWaitingScreen(progress: mailboxStage()),
        FakeApiClient(resetRoutes()),
      );
      expect(find.text('إعادة التعيين قيد الانتظار'), findsOneWidget);
      expect(find.text('تحقّق من بريدك الإلكتروني'), findsOneWidget);
      expect(find.text('إلغاء الطلب'), findsOneWidget);
      expectRtl(tester);
    });

    testWidgets('witness entry', (tester) async {
      await pumpArabic(
        tester,
        const MfaResetWitnessScreen(requestId: 'req-1'),
        FakeApiClient(resetRoutes()),
      );
      expect(find.text('أدخل رمز إعادة التعيين'), findsOneWidget);
      expect(find.text('رمز من 8 أرقام'), findsOneWidget);
      expectRtl(tester);
    });

    testWidgets('co-parent approval', (tester) async {
      await pumpArabic(
        tester,
        const MfaResetApprovalScreen(requestId: 'req-1'),
        FakeApiClient(resetRoutes()),
      );
      expect(find.text('الموافقة على طلب إعادة تعيين'), findsOneWidget);
      expect(find.text('موافقة'), findsOneWidget);
      expect(find.text('رفض'), findsOneWidget);
      expectRtl(tester);
    });

    testWidgets('witness failure copy', (tester) async {
      await pumpArabic(
        tester,
        const MfaResetWitnessScreen(requestId: 'req-1'),
        FakeApiClient(resetRoutes(
          witness: (_) => const FakeHttpError(401, {'error': 'invalid_witness', 'attemptsRemaining': 2}),
        )),
      );
      await tester.enterText(find.byKey(const ValueKey('mfaResetWitnessCode')), '00000000');
      await tester.tap(find.byKey(const ValueKey('mfaResetWitnessSubmit')));
      await flush(tester);
      await tester.pumpAndSettle();

      expect(find.text('لم يُقبل هذا الرمز. المحاولات المتبقية: 2.'), findsOneWidget);
      expectRtl(tester);
    });
  });

  group('Reset ARB key parity', () {
    Map<String, dynamic> readArb(String name) =>
        jsonDecode(File('lib/l10n/$name').readAsStringSync()) as Map<String, dynamic>;

    Set<String> resetKeys(Map<String, dynamic> arb) =>
        {for (final k in arb.keys) if (k.startsWith('mfaReset') && !k.startsWith('@')) k};

    test('every reset key exists, is non-empty and keeps its placeholders in Arabic', () {
      final en = readArb('app_en.arb');
      final ar = readArb('app_ar.arb');
      final keys = resetKeys(en);
      expect(keys, isNotEmpty);
      expect(resetKeys(ar), keys);

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
