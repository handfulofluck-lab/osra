import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:familyshield_parent/api/mfa_reset_store.dart';
import 'package:familyshield_parent/app.dart';
import 'package:familyshield_parent/features/auth/mfa_recovery_screen.dart';
import 'package:familyshield_parent/features/auth/mfa_reset_approval_screen.dart';
import 'package:familyshield_parent/features/auth/mfa_reset_request_screen.dart';
import 'package:familyshield_parent/features/auth/mfa_reset_waiting_screen.dart';
import 'package:familyshield_parent/features/auth/mfa_reset_witness_screen.dart';
import 'package:familyshield_parent/features/dashboard/dashboard_screen.dart';
import 'package:familyshield_parent/features/settings/mfa_enroll_screen.dart';
import 'package:familyshield_parent/features/settings/mfa_settings_screen.dart';
import 'package:familyshield_parent/l10n/l10n.dart';
import 'package:familyshield_parent/providers/auth_provider.dart';
import 'package:familyshield_parent/providers/onboarding_provider.dart';

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

  /// A `POST /mfa/reset/status` body: an open state by default, and the two
  /// date fields that state owns.
  ///
  /// [mailboxLinkExpiresAt] and [codeExpiresAt] override their defaults so a
  /// test can hand the screen a deadline that has already run out;
  /// [deviceCode] false is the API's answer when the family had no paired
  /// device, which is the only time `codeExpiresAt` is null in
  /// `mailbox_confirmed`.
  Map<String, dynamic> statusPayload({
    String state = 'mailbox_confirmed',
    DateTime? mailboxLinkExpiresAt,
    DateTime? codeExpiresAt,
    DateTime? witnessDeadline,
    bool deviceCode = true,
  }) {
    final now = DateTime.now().toUtc();
    return {
      'requestId': 'req-1',
      'state': state,
      'createdAt': now.subtract(const Duration(hours: 1)).toIso8601String(),
      'emailConfirmedAt': state == 'requested' ? null : now.subtract(const Duration(minutes: 20)).toIso8601String(),
      'mailboxLinkExpiresAt':
          state == 'requested' ? (mailboxLinkExpiresAt ?? now.add(const Duration(minutes: 10))).toIso8601String() : null,
      'witnessDeadline': state == 'mailbox_confirmed'
          ? (witnessDeadline ?? now.add(const Duration(hours: 23))).toIso8601String()
          : null,
      'codeExpiresAt': state == 'mailbox_confirmed' && deviceCode
          ? (codeExpiresAt ?? now.add(const Duration(minutes: 8))).toIso8601String()
          : null,
      'attemptsRemaining': state == 'mailbox_confirmed' ? 5 : null,
      'witnessKind': state == 'witness_passed' ? 'device' : null,
      'witnessAt': state == 'witness_passed' ? now.subtract(const Duration(minutes: 5)).toIso8601String() : null,
      'windowEndsAt': state == 'witness_passed' ? windowEnd.toIso8601String() : null,
      'outcomeAt': const {'requested', 'mailbox_confirmed', 'witness_passed'}.contains(state)
          ? null
          : DateTime.now().toUtc().toIso8601String(),
    };
  }

  Map<String, dynamic> pendingRequest({
    String requestId = 'req-9',
    String state = 'mailbox_confirmed',
    String name = 'Fatima',
    String role = 'co-parent',
  }) =>
      {
        'requestId': requestId,
        'state': state,
        'requester': {'parentId': 'par-2', 'displayName': name, 'role': role},
        'createdAt': DateTime.now().toUtc().subtract(const Duration(hours: 2)).toIso8601String(),
        'emailConfirmedAt': DateTime.now().toUtc().subtract(const Duration(hours: 1)).toIso8601String(),
        'witnessDeadline': DateTime.now().toUtc().add(const Duration(hours: 23)).toIso8601String(),
        'windowEndsAt': state == 'witness_passed' ? windowEnd.toIso8601String() : null,
      };

  Map<String, FakeRoute> resetRoutes({
    FakeRoute? request,
    FakeRoute? witness,
    FakeRoute? approve,
    FakeRoute? cancel,
    FakeRoute? complete,
    FakeRoute? status,
    FakeRoute? pending,
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
        'POST /v1/auth/mfa/reset/status': status ?? (_) => statusPayload(),
        'GET /v1/auth/mfa/reset/pending': pending ?? (_) => {'requests': <dynamic>[]},
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
      expect(find.byKey(const ValueKey('mfaResetCancelHint')), findsOneWidget);
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

    // The parent on this screen is the one being reset and has no session, so
    // the real `/cancel` answers `401 unauthorized` (or `session_revoked` once
    // the window starts). A cancel button here could only ever fail; the screen
    // names the two ways that work instead (ADR-0031 amendment 2026-10-23).
    for (final (name, progress) in [
      ('awaiting the mailbox', mailboxStage()),
      ('awaiting the witness', MfaResetProgress(requestId: 'req-1', stage: MfaResetStage.awaitingWitness)),
      ('in the window', MfaResetProgress(requestId: 'req-1', stage: MfaResetStage.window, windowEndsAt: windowEnd)),
    ]) {
      testWidgets('$name: no cancel button, and the two real ways to stop the request are named', (tester) async {
        final api = FakeApiClient(resetRoutes());
        await pumpScreen(tester, MfaResetWaitingScreen(progress: progress), api);

        expect(find.byKey(const ValueKey('mfaResetCancel')), findsNothing);
        expect(find.byKey(const ValueKey('mfaResetCancelHint')), findsOneWidget);
        expect(find.textContaining('cancel link in any email about it'), findsOneWidget);
        expect(find.textContaining('Signing in with your authenticator also cancels it'), findsOneWidget);
        expect(api.calls('POST', '/v1/auth/mfa/reset/cancel'), isEmpty);
      });
    }

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
      // Start-again is never offered in the window: the API answers 409
      // reset_already_pending, so the button could only fail.
      expect(find.byKey(const ValueKey('mfaResetStartAgain')), findsNothing);
      expect(find.byKey(const ValueKey('mfaResetDeadlinePassed')), findsNothing);
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
      // Even with the wait over, the window offers no start-again.
      expect(find.byKey(const ValueKey('mfaResetStartAgain')), findsNothing);
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

  group('Restart path: the waiting screen re-reads the server (gap 1)', () {
    void storeRequest({String id = 'req-1', String email = 'qa@familyshield.dev'}) =>
        FlutterSecureStorage.setMockInitialValues({
          MfaResetStore.requestIdKey: id,
          MfaResetStore.emailKey: email,
        });

    Future<void> submitPassword(WidgetTester tester) async {
      await tester.enterText(find.byKey(const ValueKey('mfaResetResumePassword')), 'good-password');
      await tester.tap(find.byKey(const ValueKey('mfaResetResumeSubmit')));
      await flush(tester);
      await tester.pumpAndSettle();
    }

    testWidgets('a stored id asks for the password once and renders the stage from status', (tester) async {
      storeRequest();
      final api = FakeApiClient(resetRoutes(status: (_) => statusPayload()));
      await pumpScreen(tester, const MfaResetWaitingScreen(), api);

      expect(find.text('Continue your reset'), findsOneWidget);
      expect(find.byKey(const ValueKey('mfaResetResumeEmail')), findsOneWidget);
      expect(find.text('qa@familyshield.dev'), findsOneWidget);
      expect(find.byKey(const ValueKey('mfaResetResumePassword')), findsOneWidget);
      // Nothing is asked twice: no email field, only the password.
      expect(find.byKey(const ValueKey('mfaResetEmail')), findsNothing);

      await submitPassword(tester);

      final call = api.calls('POST', '/v1/auth/mfa/reset/status').single;
      expect(call.body['email'], 'qa@familyshield.dev');
      expect(call.body['password'], 'good-password');
      expect(call.body['requestId'], 'req-1');

      expect(find.byKey(const ValueKey('mfaResetStageTitle')), findsOneWidget);
      expect(find.text('Waiting for the witness step'), findsOneWidget);
      expect(find.byKey(const ValueKey('mfaResetDeadline')), findsOneWidget);
      expect(find.byKey(const ValueKey('mfaResetHaveCode')), findsOneWidget);

      // The password is not kept anywhere; the request id and address are.
      final stored = await const FlutterSecureStorage().readAll();
      expect(stored[MfaResetStore.requestIdKey], 'req-1');
      expect(stored[MfaResetStore.emailKey], 'qa@familyshield.dev');
      expect(stored.values, isNot(contains('good-password')));
    });

    testWidgets('a restored mailbox stage keeps the link deadline', (tester) async {
      storeRequest();
      final api = FakeApiClient(resetRoutes(status: (_) => statusPayload(state: 'requested')));
      await pumpScreen(tester, const MfaResetWaitingScreen(), api);
      await submitPassword(tester);

      expect(find.text('Check your email'), findsOneWidget);
      expect(find.textContaining('within 30 minutes'), findsOneWidget);
      expect(find.byKey(const ValueKey('mfaResetDeadline')), findsOneWidget);
      // Live and resumed share the mailbox wording: the route says nothing a
      // live screen did not already know.
      expect(find.text('Waiting for the witness step'), findsNothing);
    });

    testWidgets('a restored window stage shows the 72-hour end and the finish action once due', (tester) async {
      storeRequest();
      final api = FakeApiClient(resetRoutes(status: (_) => statusPayload(state: 'witness_passed')));
      await pumpScreen(tester, const MfaResetWaitingScreen(), api);
      await submitPassword(tester);

      expect(find.text('The 72-hour wait has started'), findsOneWidget);
      expect(find.byKey(const ValueKey('mfaResetDeadline')), findsOneWidget);
      expect(find.byKey(const ValueKey('mfaResetFinish')), findsNothing);
    });

    testWidgets('401 invalid_credentials keeps the one honest refusal and the request on file', (tester) async {
      storeRequest();
      final api = FakeApiClient(resetRoutes(
        status: (_) => const FakeHttpError(401, {'error': 'invalid_credentials'}),
      ));
      await pumpScreen(tester, const MfaResetWaitingScreen(), api);
      await submitPassword(tester);

      expect(find.byKey(const ValueKey('mfaResetResumeError')), findsOneWidget);
      expect(find.text('The email or password is incorrect.'), findsOneWidget);
      expect(find.byKey(const ValueKey('mfaResetStageTitle')), findsNothing);
      expect(find.byKey(const ValueKey('mfaResetResumePassword')), findsOneWidget);
      expect(await const FlutterSecureStorage().read(key: MfaResetStore.requestIdKey), 'req-1');
      // The password was used for the one call and dropped, refusal or not.
      expect(tester.widget<TextField>(find.byKey(const ValueKey('mfaResetResumePassword'))).controller!.text, isEmpty);
    });

    testWidgets('a status call that throws still drops the password and keeps the id', (tester) async {
      storeRequest();
      final api = FakeApiClient(resetRoutes(status: (_) => const FakeNetworkError()));
      await pumpScreen(tester, const MfaResetWaitingScreen(), api);
      await submitPassword(tester);

      expect(find.byKey(const ValueKey('mfaResetResumeError')), findsOneWidget);
      expect(find.text('Could not reach the server. Check your connection and try again.'), findsOneWidget);
      // Cleared on the failing path too: the throw must not keep it in the field.
      expect(tester.widget<TextField>(find.byKey(const ValueKey('mfaResetResumePassword'))).controller!.text, isEmpty);
      expect(await const FlutterSecureStorage().read(key: MfaResetStore.requestIdKey), 'req-1');
      expect(
        (await const FlutterSecureStorage().readAll()).values.contains('good-password'),
        isFalse,
      );
    });

    testWidgets('404 request_not_found is "gone — start again", and the saved id is cleared', (tester) async {
      storeRequest();
      final api = FakeApiClient(resetRoutes(
        status: (_) => const FakeHttpError(404, {'error': 'request_not_found'}),
      ));
      await pumpScreen(tester, const MfaResetWaitingScreen(), api);
      await submitPassword(tester);

      expect(find.byKey(const ValueKey('mfaResetTerminalTitle')), findsOneWidget);
      expect(
        find.text('This request no longer exists, so nothing was changed. Start again from the beginning.'),
        findsOneWidget,
      );
      expect(await const FlutterSecureStorage().read(key: MfaResetStore.requestIdKey), isNull);

      await tester.tap(find.byKey(const ValueKey('mfaResetStartAgain')));
      await tester.pumpAndSettle();
      expect(find.byType(MfaResetRequestScreen), findsOneWidget);
    });

    testWidgets('a mailbox link that ran out offers a new request, not a code', (tester) async {
      storeRequest();
      final api = FakeApiClient(resetRoutes(
        status: (_) => statusPayload(
          state: 'requested',
          mailboxLinkExpiresAt: DateTime.now().toUtc().subtract(const Duration(hours: 1)),
        ),
      ));
      await pumpScreen(tester, const MfaResetWaitingScreen(), api);
      await submitPassword(tester);

      expect(find.byKey(const ValueKey('mfaResetDeadlinePassed')), findsOneWidget);
      expect(find.text('This link or code has run out. A new request replaces this one.'), findsOneWidget);
      expect(find.byKey(const ValueKey('mfaResetHaveCode')), findsNothing);

      await tester.tap(find.byKey(const ValueKey('mfaResetStartAgain')));
      await tester.pumpAndSettle();
      await flush(tester);

      expect(find.byType(MfaResetRequestScreen), findsOneWidget);
      expect(find.byKey(const ValueKey('mfaResetEmail')), findsOneWidget);
      expect(await const FlutterSecureStorage().read(key: MfaResetStore.requestIdKey), isNull);
      expect(await const FlutterSecureStorage().read(key: MfaResetStore.emailKey), isNull);
    });

    testWidgets('a mailbox link that ran out minutes ago still offers the code', (tester) async {
      // ADR-0031: a link opened in its last second issues a device code valid 10 more minutes, so
      // start-again five minutes after the link expired would supersede a request whose code works
      // and spend one of the parent's three attempts in 30 days (#314 review).
      storeRequest();
      final api = FakeApiClient(resetRoutes(
        status: (_) => statusPayload(
          state: 'requested',
          mailboxLinkExpiresAt: DateTime.now().toUtc().subtract(const Duration(minutes: 5)),
        ),
      ));
      await pumpScreen(tester, const MfaResetWaitingScreen(), api);
      await submitPassword(tester);

      expect(find.byKey(const ValueKey('mfaResetDeadlinePassed')), findsNothing);
      expect(find.byKey(const ValueKey('mfaResetStartAgain')), findsNothing);
      expect(find.byKey(const ValueKey('mfaResetHaveCode')), findsOneWidget);
    });

    testWidgets('with no device code, a past 24-hour approval deadline offers a new request', (tester) async {
      storeRequest();
      final api = FakeApiClient(resetRoutes(
        status: (_) => statusPayload(
          state: 'mailbox_confirmed',
          deviceCode: false,
          witnessDeadline: DateTime.now().toUtc().subtract(const Duration(hours: 1)),
        ),
      ));
      await pumpScreen(tester, const MfaResetWaitingScreen(), api);
      await submitPassword(tester);

      expect(find.byKey(const ValueKey('mfaResetDeadlinePassed')), findsOneWidget);
      expect(find.byKey(const ValueKey('mfaResetHaveCode')), findsNothing);
      // A past "by {time}" beside a start-again button would read as a reason to keep waiting.
      expect(find.byKey(const ValueKey('mfaResetAwaitingCoParent')), findsNothing);
    });

    testWidgets('a device code that ran out offers a new request too', (tester) async {
      storeRequest();
      final api = FakeApiClient(resetRoutes(
        status: (_) => statusPayload(
          codeExpiresAt: DateTime.now().toUtc().subtract(const Duration(hours: 1)),
        ),
      ));
      await pumpScreen(tester, const MfaResetWaitingScreen(), api);
      await submitPassword(tester);

      expect(find.byKey(const ValueKey('mfaResetDeadlinePassed')), findsOneWidget);
      expect(find.byKey(const ValueKey('mfaResetHaveCode')), findsNothing);
      expect(find.text('Enter the code'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('mfaResetStartAgain')));
      await tester.pumpAndSettle();
      await flush(tester);

      expect(find.byType(MfaResetRequestScreen), findsOneWidget);
      expect(find.byKey(const ValueKey('mfaResetEmail')), findsOneWidget);
      expect(await const FlutterSecureStorage().read(key: MfaResetStore.requestIdKey), isNull);
    });

    testWidgets('a request with no device code offers no code entry and names the co-parent', (tester) async {
      storeRequest();
      final api = FakeApiClient(resetRoutes(status: (_) => statusPayload(deviceCode: false)));
      await pumpScreen(tester, const MfaResetWaitingScreen(), api);
      await submitPassword(tester);

      expect(find.byKey(const ValueKey('mfaResetHaveCode')), findsNothing);
      expect(find.text('Enter the code'), findsNothing);
      expect(find.byKey(const ValueKey('mfaResetAwaitingCoParent')), findsOneWidget);
      expect(find.textContaining('Waiting for another parent in your family to approve'), findsOneWidget);
      // No code deadline to show, and the request is still live.
      expect(find.byKey(const ValueKey('mfaResetDeadline')), findsNothing);
      expect(await const FlutterSecureStorage().read(key: MfaResetStore.requestIdKey), 'req-1');
    });

    for (final (state, copy, offersStart) in [
      (
        'cancelled_by_signin',
        'A successful sign-in cancels a reset request, so nothing was changed. '
            'If you still need to reset two-step verification, start a new request.',
        true,
      ),
      (
        'cancelled_by_link',
        'This request was cancelled, so nothing was changed. '
            'If you still need to reset two-step verification, start a new request.',
        true,
      ),
      (
        'cancelled_by_parent',
        'This request was cancelled, so nothing was changed. '
            'If you still need to reset two-step verification, start a new request.',
        true,
      ),
      (
        'expired',
        'This request expired before it finished, so nothing was changed. Start a new request when you are ready.',
        true,
      ),
      (
        'too_many_attempts',
        'Five wrong codes ended this request, so nothing was changed. '
            'Have the child whose phone shows the code with you, then start a new request.',
        true,
      ),
      (
        'completed',
        'This reset was completed. Sign in with your new authenticator; '
            'if you have not set it up yet, do that first.',
        false,
      ),
    ]) {
      testWidgets('state $state says what happened and what to do next', (tester) async {
        storeRequest();
        final api = FakeApiClient(resetRoutes(status: (_) => statusPayload(state: state)));
        await pumpScreen(tester, const MfaResetWaitingScreen(), api);
        await submitPassword(tester);

        expect(find.byKey(const ValueKey('mfaResetTerminalTitle')), findsOneWidget);
        expect(find.text(copy), findsOneWidget);
        expect(
          find.byKey(const ValueKey('mfaResetStartAgain')),
          offersStart ? findsOneWidget : findsNothing,
        );
        expect(await const FlutterSecureStorage().read(key: MfaResetStore.requestIdKey), isNull);
      });
    }

    testWidgets('a successful request saves the id and address, never the password', (tester) async {
      final api = FakeApiClient(resetRoutes());
      await pumpScreen(tester, const MfaResetRequestScreen(), api);

      await tester.enterText(find.byKey(const ValueKey('mfaResetEmail')), 'qa@familyshield.dev');
      await tester.enterText(find.byKey(const ValueKey('mfaResetPassword')), 'good-password');
      await tester.tap(find.byKey(const ValueKey('mfaResetSubmit')));
      await flush(tester);
      await tester.pumpAndSettle();

      expect(find.byType(MfaResetWaitingScreen), findsOneWidget);
      final stored = await const FlutterSecureStorage().readAll();
      expect(stored[MfaResetStore.requestIdKey], 'req-1');
      expect(stored[MfaResetStore.emailKey], 'qa@familyshield.dev');
      expect(stored.values, isNot(contains('good-password')));
    });

    testWidgets('opening the request screen with a saved request resumes instead of asking again', (tester) async {
      storeRequest();
      final api = FakeApiClient(resetRoutes());
      await pumpScreen(tester, const MfaResetRequestScreen(), api);
      await tester.pumpAndSettle();

      expect(find.byType(MfaResetWaitingScreen), findsOneWidget);
      expect(find.byKey(const ValueKey('mfaResetResumePassword')), findsOneWidget);
      expect(find.byKey(const ValueKey('mfaResetEmail')), findsNothing);
    });
  });

  group('Pending list: a co-parent gets a name and a way in (gap 2)', () {
    testWidgets('an owner sees the banner, and the approval prompt names the requester', (tester) async {
      final api = FakeApiClient(resetRoutes(
        pending: (_) => {'requests': [pendingRequest()]},
      ));
      await pumpScreen(tester, const DashboardScreen(), api);
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('mfaResetPendingBanner')), findsOneWidget);
      expect(find.text('Fatima (co-parent) asked to reset their two-step verification.'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('mfaResetPendingReview')));
      await tester.pumpAndSettle();

      expect(find.byType(MfaResetApprovalScreen), findsOneWidget);
      expect(find.textContaining('Fatima (co-parent) asked to reset'), findsOneWidget);
      expect(find.textContaining('Another parent in your family'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('mfaResetApprove')));
      await flush(tester);
      await tester.pumpAndSettle();

      expect(api.calls('POST', '/v1/auth/mfa/reset/approve').single.body['requestId'], 'req-9');
      expect(find.byKey(const ValueKey('mfaResetApproved')), findsOneWidget);
    });

    testWidgets('a guardian gets the 403 and sees nothing on the dashboard, not an error page', (tester) async {
      final api = FakeApiClient(resetRoutes(
        pending: (_) => const FakeHttpError(403, {'error': 'role_not_allowed'}),
      ));
      await pumpScreen(tester, const DashboardScreen(), api);
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('mfaResetPendingBanner')), findsNothing);
      expect(find.textContaining('Only an owner or co-parent'), findsNothing);
      expect(find.text('Alex'), findsOneWidget);
    });

    testWidgets('a guardian sees nothing in settings either', (tester) async {
      final api = FakeApiClient(resetRoutes(
        pending: (_) => const FakeHttpError(403, {'error': 'role_not_allowed'}),
      ));
      await pumpScreen(tester, const MfaSettingsScreen(mfaEnabledOverride: true), api);
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('mfaResetPendingSection')), findsNothing);
      expect(find.text('Two-step verification'), findsOneWidget);
    });

    testWidgets('an empty list shows no prompt at all', (tester) async {
      final api = FakeApiClient(resetRoutes());
      await pumpScreen(tester, const DashboardScreen(), api);
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('mfaResetPendingBanner')), findsNothing);
      expect(find.byKey(const ValueKey('mfaResetPendingSection')), findsNothing);
    });

    testWidgets('settings lists the request and opens the named prompt', (tester) async {
      final api = FakeApiClient(resetRoutes(
        pending: (_) => {'requests': [pendingRequest()]},
      ));
      await pumpScreen(tester, const MfaSettingsScreen(mfaEnabledOverride: true), api);
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('mfaResetPendingSection')), findsOneWidget);
      expect(find.byKey(const ValueKey('mfaResetPendingItem-req-9')), findsOneWidget);
      expect(find.text('Fatima'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('mfaResetPendingItem-req-9')));
      await tester.pumpAndSettle();

      expect(find.byType(MfaResetApprovalScreen), findsOneWidget);
      expect(find.textContaining('Fatima (co-parent)'), findsOneWidget);
      expect(api.calls('POST', '/v1/auth/mfa/reset/approve'), isEmpty);
    });

    testWidgets('a request that already passed its witness shows the window and no Approve button', (tester) async {
      final api = FakeApiClient(resetRoutes(
        pending: (_) => {'requests': [pendingRequest(state: 'witness_passed')]},
      ));
      await pumpScreen(tester, const DashboardScreen(), api);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('mfaResetPendingReview')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('mfaResetApproveAlready')), findsOneWidget);
      expect(find.byKey(const ValueKey('mfaResetApprove')), findsNothing);
      expect(find.byKey(const ValueKey('mfaResetDecline')), findsOneWidget);
    });
  });

  group('Approval with a real name (gap 2)', () {
    testWidgets('the named prompt replaces "another parent in your family"', (tester) async {
      final api = FakeApiClient(resetRoutes());
      await pumpScreen(
        tester,
        const MfaResetApprovalScreen(
          requestId: 'req-9',
          requesterName: 'Fatima',
          requesterRole: 'co-parent',
        ),
        api,
      );

      expect(find.textContaining('Fatima (co-parent)'), findsOneWidget);
      expect(find.textContaining('Another parent in your family'), findsNothing);
      expect(find.byKey(const ValueKey('mfaResetApprove')), findsOneWidget);
    });

    testWidgets('a request with no name keeps the old wording instead of inventing one', (tester) async {
      final api = FakeApiClient(resetRoutes());
      await pumpScreen(tester, const MfaResetApprovalScreen(requestId: 'req-9'), api);

      expect(find.textContaining('Another parent in your family'), findsOneWidget);
    });
  });

  group('Approval deep link: only the id comes from the URL (review of #314)', () {
    testWidgets('the name, role and state are read from /pending by id', (tester) async {
      final api = FakeApiClient(resetRoutes(
        pending: (_) => {
          'requests': [pendingRequest(requestId: 'req-9', name: 'Fatima', role: 'co-parent')],
        },
      ));
      await pumpScreen(tester, const MfaResetApprovalLink(requestId: 'req-9'), api);
      await tester.pumpAndSettle();

      expect(find.textContaining('Fatima (co-parent)'), findsOneWidget);
      expect(find.textContaining('Another parent in your family'), findsNothing);
      expect(find.byKey(const ValueKey('mfaResetApprove')), findsOneWidget);
    });

    testWidgets('an id that is not in the list falls back to the generic copy', (tester) async {
      // The list must hold a *different* request: with an empty list a builder that takes the first
      // entry regardless of id passes, which is what Claude's `if (true)` mutant showed (#314 review).
      final api = FakeApiClient(resetRoutes(
        pending: (_) => {
          'requests': [pendingRequest(requestId: 'req-9', name: 'Fatima', role: 'co-parent')],
        },
      ));
      await pumpScreen(tester, const MfaResetApprovalLink(requestId: 'req-404'), api);
      await tester.pumpAndSettle();

      expect(find.textContaining('Another parent in your family'), findsOneWidget);
      expect(find.textContaining('Fatima'), findsNothing);
      expect(find.byKey(const ValueKey('mfaResetApprove')), findsOneWidget);
    });

    testWidgets('a crafted link cannot name the requester or hide Approve', (tester) async {
      FlutterSecureStorage.setMockInitialValues({'jwt': 'jwt-token'});
      SharedPreferences.setMockInitialValues({kOnboardingCompleteKey: true});
      final api = FakeApiClient(resetRoutes(
        pending: (_) => {
          'requests': [pendingRequest(requestId: 'req-9', name: 'Fatima', role: 'co-parent')],
        },
      ));
      await tester.pumpWidget(ProviderScope(
        overrides: [apiClientProvider.overrideWithValue(api)],
        child: const FamilyShieldApp(),
      ));
      for (var i = 0; i < 40 && find.byType(DashboardScreen).evaluate().isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.byType(DashboardScreen), findsOneWidget);

      router.go('/mfa/reset/approve'
          '?requestId=req-9&name=Mallory&role=owner&state=witness_passed'
          '&windowEndsAt=${windowEnd.toIso8601String()}');
      await tester.pumpAndSettle();

      expect(find.byType(MfaResetApprovalScreen), findsOneWidget);
      expect(find.textContaining('Fatima (co-parent)'), findsOneWidget);
      expect(find.textContaining('Mallory'), findsNothing);
      // The URL said witness_passed; /pending says otherwise, so Approve stays.
      expect(find.byKey(const ValueKey('mfaResetApprove')), findsOneWidget);
      expect(find.byKey(const ValueKey('mfaResetApproveAlready')), findsNothing);

      await tester.pumpWidget(const SizedBox());
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
      expect(find.textContaining('افتح رابط الإلغاء في أي بريد وصلك بشأنه'), findsOneWidget);
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

    testWidgets('resume prompt', (tester) async {
      FlutterSecureStorage.setMockInitialValues({
        MfaResetStore.requestIdKey: 'req-1',
        MfaResetStore.emailKey: 'qa@familyshield.dev',
      });
      await pumpArabic(tester, const MfaResetWaitingScreen(), FakeApiClient(resetRoutes()));
      expect(find.text('متابعة إعادة التعيين'), findsOneWidget);
      expect(find.textContaining('لا يزال هناك طلب إعادة تعيين محفوظ'), findsOneWidget);
      expect(find.text('متابعة'), findsOneWidget);
      expectRtl(tester);
    });

    testWidgets('resumed witness stage', (tester) async {
      FlutterSecureStorage.setMockInitialValues({
        MfaResetStore.requestIdKey: 'req-1',
        MfaResetStore.emailKey: 'qa@familyshield.dev',
      });
      await pumpArabic(tester, const MfaResetWaitingScreen(), FakeApiClient(resetRoutes()));
      await tester.enterText(find.byKey(const ValueKey('mfaResetResumePassword')), 'good-password');
      await tester.tap(find.byKey(const ValueKey('mfaResetResumeSubmit')));
      await flush(tester);
      await tester.pumpAndSettle();

      expect(find.text('بانتظار خطوة الشاهد'), findsOneWidget);
      expectRtl(tester);
    });

    testWidgets('terminal copy', (tester) async {
      FlutterSecureStorage.setMockInitialValues({
        MfaResetStore.requestIdKey: 'req-1',
        MfaResetStore.emailKey: 'qa@familyshield.dev',
      });
      await pumpArabic(
        tester,
        const MfaResetWaitingScreen(),
        FakeApiClient(resetRoutes(status: (_) => statusPayload(state: 'cancelled_by_parent'))),
      );
      await tester.enterText(find.byKey(const ValueKey('mfaResetResumePassword')), 'good-password');
      await tester.tap(find.byKey(const ValueKey('mfaResetResumeSubmit')));
      await flush(tester);
      await tester.pumpAndSettle();

      expect(find.text('انتهى طلب إعادة التعيين هذا'), findsOneWidget);
      expect(find.textContaining('تم إلغاء هذا الطلب، لذلك لم يتغيّر شيء'), findsOneWidget);
      expect(find.text('ابدأ طلبًا جديدًا'), findsOneWidget);
      expectRtl(tester);
    });

    testWidgets('pending banner and named approval', (tester) async {
      await pumpArabic(
        tester,
        const DashboardScreen(),
        FakeApiClient(resetRoutes(
          pending: (_) => {'requests': [pendingRequest(name: 'فاطمة')]},
        )),
      );
      await tester.pumpAndSettle();

      expect(find.text('وصل طلب من فاطمة (والد مشارك) لإعادة تعيين التحقق بخطوتين.'), findsOneWidget);
      expectRtl(tester);

      await tester.tap(find.byKey(const ValueKey('mfaResetPendingReview')));
      await tester.pumpAndSettle();

      expect(find.textContaining('وصل طلب من فاطمة (والد مشارك)'), findsOneWidget);
      expectRtl(tester);
    });

    testWidgets('deadline passed', (tester) async {
      FlutterSecureStorage.setMockInitialValues({
        MfaResetStore.requestIdKey: 'req-1',
        MfaResetStore.emailKey: 'qa@familyshield.dev',
      });
      await pumpArabic(
        tester,
        const MfaResetWaitingScreen(),
        FakeApiClient(resetRoutes(
          status: (_) => statusPayload(
            state: 'requested',
            mailboxLinkExpiresAt: DateTime.now().toUtc().subtract(const Duration(hours: 1)),
          ),
        )),
      );
      await tester.enterText(find.byKey(const ValueKey('mfaResetResumePassword')), 'good-password');
      await tester.tap(find.byKey(const ValueKey('mfaResetResumeSubmit')));
      await flush(tester);
      await tester.pumpAndSettle();

      expect(find.textContaining('انتهت صلاحية هذا الرابط أو الرمز'), findsOneWidget);
      expect(find.text('ابدأ طلبًا جديدًا'), findsOneWidget);
      expect(find.byKey(const ValueKey('mfaResetHaveCode')), findsNothing);
      expectRtl(tester);
    });

    testWidgets('co-parent only witness', (tester) async {
      FlutterSecureStorage.setMockInitialValues({
        MfaResetStore.requestIdKey: 'req-1',
        MfaResetStore.emailKey: 'qa@familyshield.dev',
      });
      await pumpArabic(
        tester,
        const MfaResetWaitingScreen(),
        FakeApiClient(resetRoutes(status: (_) => statusPayload(deviceCode: false))),
      );
      await tester.enterText(find.byKey(const ValueKey('mfaResetResumePassword')), 'good-password');
      await tester.tap(find.byKey(const ValueKey('mfaResetResumeSubmit')));
      await flush(tester);
      await tester.pumpAndSettle();

      expect(find.textContaining('بانتظار موافقة والد آخر في عائلتك'), findsOneWidget);
      expect(find.text('أدخل الرمز'), findsNothing);
      expectRtl(tester);
    });
  });

  group('Arabic copy (review of #314)', () {
    Future<AppLocalizations> arabic() => AppLocalizations.delegate.load(const Locale('ar'));

    test('the "more requests" line agrees with the count', () async {
      final ar = await arabic();
      expect(ar.mfaResetPendingMore(1), 'وطلب آخر');
      expect(ar.mfaResetPendingMore(2), 'وطلبان آخران');
      expect(ar.mfaResetPendingMore(11), 'و11 طلبًا آخر');
    });

    test('the witness step is passed, never "bypassed"', () async {
      final ar = await arabic();
      for (final text in [ar.mfaResetApproveAlready, ar.mfaResetPendingAlreadyWaiting('والد مشارك')]) {
        expect(text.contains('تجاوز'), isFalse, reason: text);
        expect(text, contains('اجتاز'));
      }
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
