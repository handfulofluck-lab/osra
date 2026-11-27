import 'dart:async';

import 'package:dio/dio.dart';
import 'package:familyshield_parent/features/pairing/pair_p05_screen.dart';
import 'package:familyshield_parent/features/pairing/pair_qr_screen.dart';
import 'package:familyshield_parent/l10n/app_localizations.dart';
import 'package:familyshield_parent/providers/auth_provider.dart';
import 'package:familyshield_parent/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_api_client.dart';

/// #1179 P-05 Pair device tests (★0, A10 + Kimi-Mac B1–B5).
///
/// Mutant checks:
/// - Treating `approved` as `p05ConnectedCard` breaks the B1 state-transition test.
/// - Reading `model` instead of `deviceName` breaks the B2 device-name test.
/// - Leaving `p05QrCodeCard` / `p05WaitingLine` visible after Deny breaks the B3 test.
/// - Dropping `pairClaimDataCleared` breaks the B4 test.
/// - Swallowing poll errors or labeling HTTP 409 as "No connection" breaks the B5 test.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  FakeApiClient buildApi({
    String code = '482913',
    DateTime? expiresAt,
    Object? Function()? claimResponse,
    Object? Function()? approveResponse,
    Object? Function()? denyResponse,
    List<String>? approvedClaims,
  }) {
    final exp = (expiresAt ?? DateTime.now().add(const Duration(minutes: 10))).toUtc().toIso8601String();
    return FakeApiClient({
      ...standardRoutes(),
      'POST /v1/devices/pair': (_) => {'code': code, 'expiresAt': exp},
      'GET /v1/devices/pair/$code/claim': (_) =>
          claimResponse != null ? claimResponse() : {'status': 'waiting'},
      'POST /v1/devices/pair/claims/claim-1/approve': (_) {
        approvedClaims?.add('claim-1');
        return approveResponse != null ? approveResponse() : {'ok': true};
      },
      'POST /v1/devices/pair/claims/claim-1/deny': (_) =>
          denyResponse != null ? denyResponse() : {'ok': true},
    });
  }

  testWidgets('#1179 P-05 B1+B2+B4: confirms deviceName over model, shows dataCleared warning, stays approved-waiting until paired', (tester) async {
    final approved = <String>[];
    final now = DateTime(2026, 11, 26, 17, 45);
    var stage = 'pending';
    final api = buildApi(
      code: '482913',
      expiresAt: now.add(const Duration(minutes: 10)),
      claimResponse: () => {
        'claimId': 'claim-1',
        'status': stage,
        'model': 'Pixel 8',
        'deviceName': "Sam's phone",
        'dataCleared': true,
      },
      approvedClaims: approved,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(api),
          p05PairEnabledProvider.overrideWithValue(true),
        ],
        child: MaterialApp(
          theme: AppTheme.light,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: PairingQrScreen(
            childId: 'child-1',
            childName: 'Alex',
            clock: () => now,
            onContinue: () {},
            onSkip: () {},
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byKey(const ValueKey('p05QrCodeCard')), findsOneWidget);
    expect(find.byKey(const ValueKey('p05QrImage')), findsOneWidget);
    expect(find.textContaining('482 · 913'), findsOneWidget);
    expect(find.text('Android'), findsNothing);
    expect(find.text('iPhone'), findsNothing);
    expect(find.text('Copy code'), findsNothing);

    // Poll -> pending claim: B2 deviceName wins, B4 dataCleared warning visible.
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byKey(const ValueKey('p05ConfirmDeviceCard')), findsOneWidget);
    expect(find.textContaining("Sam's phone"), findsOneWidget);
    expect(find.textContaining('Pixel 8'), findsNothing);
    expect(find.byKey(const ValueKey('pairClaimDataCleared')), findsOneWidget);

    // Tap Confirm -> B1: status is `approved`, NOT connected yet, Continue NOT shown.
    stage = 'approved';
    await tester.scrollUntilVisible(find.byKey(const ValueKey('p05ConfirmLinkButton')), 200);
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('p05ConfirmLinkButton')));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));

    expect(approved, ['claim-1']);
    expect(find.byKey(const ValueKey('p05ApprovedCard')), findsOneWidget);
    expect(find.byKey(const ValueKey('p05ConnectedCard')), findsNothing);
    expect(find.byKey(const ValueKey('p05ContinueButton')), findsNothing);

    // Next poll returns `paired` -> now shows Phone connected + Continue.
    stage = 'paired';
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byKey(const ValueKey('p05ConnectedCard')), findsOneWidget);
    expect(find.byKey(const ValueKey('p05ContinueButton')), findsOneWidget);
  });

  testWidgets('#1179 P-05 B3: Decline hides dead QR and waiting line and offers New code', (tester) async {
    final now = DateTime(2026, 11, 26, 17, 45);
    final api = buildApi(
      expiresAt: now.add(const Duration(minutes: 10)),
      claimResponse: () => {
        'claimId': 'claim-1',
        'status': 'pending',
        'model': 'Pixel 8',
      },
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(api),
          p05PairEnabledProvider.overrideWithValue(true),
        ],
        child: MaterialApp(
          theme: AppTheme.light,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: PairingQrScreen(childId: 'child-1', childName: 'Alex', clock: () => now),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(milliseconds: 50));

    await tester.scrollUntilVisible(find.byKey(const ValueKey('p05DeclineButton')), 200);
    await tester.tap(find.byKey(const ValueKey('p05DeclineButton')));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byKey(const ValueKey('p05DeniedCard')), findsOneWidget);
    expect(find.byKey(const ValueKey('p05DeniedNewCodeButton')), findsOneWidget);
    expect(find.byKey(const ValueKey('p05QrCodeCard')), findsNothing);
    expect(find.byKey(const ValueKey('p05WaitingLine')), findsNothing);
  });

  testWidgets('#1179 P-05 B5: polling error shows honest retry while keeping QR visible, and 409 approve does not say No connection', (tester) async {
    final now = DateTime(2026, 11, 26, 17, 45);
    var failPoll = true;
    final api = buildApi(
      expiresAt: now.add(const Duration(minutes: 10)),
      claimResponse: () {
        if (failPoll) throw FakeNetworkError();
        return {'claimId': 'claim-1', 'status': 'pending', 'model': 'Pixel 8'};
      },
      approveResponse: () => throw DioException(
        requestOptions: RequestOptions(path: '/v1/devices/pair/claims/claim-1/approve'),
        response: Response(
          requestOptions: RequestOptions(path: '/v1/devices/pair/claims/claim-1/approve'),
          statusCode: 409,
          data: {'error': 'conflict'},
        ),
        type: DioExceptionType.badResponse,
      ),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(api),
          p05PairEnabledProvider.overrideWithValue(true),
        ],
        child: MaterialApp(
          theme: AppTheme.light,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: PairingQrScreen(childId: 'child-1', childName: 'Alex', clock: () => now),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byKey(const ValueKey('p05PollErrorCard')), findsOneWidget);
    expect(find.byKey(const ValueKey('p05QrCodeCard')), findsOneWidget);

    // Recover poll -> pending claim -> 409 on approve shows pairClaimError, NOT "No connection".
    failPoll = false;
    await tester.ensureVisible(find.byKey(const ValueKey('p05PollRetryButton')));
    await tester.tap(find.byKey(const ValueKey('p05PollRetryButton')));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byKey(const ValueKey('p05ConfirmDeviceCard')), findsOneWidget);

    await tester.scrollUntilVisible(find.byKey(const ValueKey('p05ConfirmLinkButton')), 200);
    await tester.tap(find.byKey(const ValueKey('p05ConfirmLinkButton')));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byKey(const ValueKey('p05DecisionError')), findsOneWidget);
    expect(find.textContaining('No connection'), findsNothing);
  });

  testWidgets('#1179 P-05 switch OFF falls back to legacy PairingQrScreen', (tester) async {
    final now = DateTime(2026, 11, 26, 17, 45);
    final api = buildApi(expiresAt: now.add(const Duration(minutes: 10)));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(api),
          p05PairEnabledProvider.overrideWithValue(false),
        ],
        child: MaterialApp(
          theme: AppTheme.light,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: PairingQrScreen(childId: 'child-1', clock: () => now),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byKey(const ValueKey('p05QrCodeCard')), findsNothing);
  });

  /// Mutant: place `else if (claimStatus == 'approved')` ahead of `else if (_pollError != null)`
  /// in `pair_p05_screen.dart` -> a status-poll failure after approval leaves `p05ApprovedCard`
  /// spinning and hides `p05PollRetryButton`.
  testWidgets('#1190 P-05 Retry fix: post-approval status poll failure prioritizes Retry over spinner and recovers to paired', (tester) async {
    final now = DateTime(2026, 11, 27, 6, 45);
    var stage = 'pending';
    var failApprovedPoll = false;
    final api = buildApi(
      code: '482913',
      expiresAt: now.add(const Duration(minutes: 10)),
      claimResponse: () {
        if (failApprovedPoll) throw const FakeNetworkError();
        return {
          'claimId': 'claim-1',
          'status': stage,
          'deviceName': "Sam's phone",
          'model': 'Pixel 8',
        };
      },
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(api),
          p05PairEnabledProvider.overrideWithValue(true),
        ],
        child: MaterialApp(
          theme: AppTheme.light,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: PairingQrScreen(
            childId: 'child-1',
            childName: 'Alex',
            clock: () => now,
            onContinue: () {},
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byKey(const ValueKey('p05ConfirmDeviceCard')), findsOneWidget);

    // Approve claim -> enters `approved` state.
    stage = 'approved';
    await tester.scrollUntilVisible(find.byKey(const ValueKey('p05ConfirmLinkButton')), 200);
    await tester.tap(find.byKey(const ValueKey('p05ConfirmLinkButton')));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byKey(const ValueKey('p05ApprovedCard')), findsOneWidget);

    // Next status poll fails -> `p05PollErrorCard` + `p05PollRetryButton` take priority over spinner.
    failApprovedPoll = true;
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byKey(const ValueKey('p05PollErrorCard')), findsOneWidget);
    expect(find.byKey(const ValueKey('p05PollRetryButton')), findsOneWidget);
    expect(find.byKey(const ValueKey('p05ApprovedCard')), findsNothing);

    // Parent taps Retry once network recovers -> transitions cleanly to `p05ConnectedCard`.
    failApprovedPoll = false;
    stage = 'paired';
    await tester.ensureVisible(find.byKey(const ValueKey('p05PollRetryButton')));
    await tester.tap(find.byKey(const ValueKey('p05PollRetryButton')));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byKey(const ValueKey('p05PollErrorCard')), findsNothing);
    expect(find.byKey(const ValueKey('p05ConnectedCard')), findsOneWidget);
    expect(find.byKey(const ValueKey('p05ContinueButton')), findsOneWidget);
  });

  /// Mutant A: leave `_code` set while `_generate()` awaits replacement or omit `_generation` check in `_readClaim()` ->
  /// a late poll from generation 1 populates `_claim` under generation 2's code.
  /// Mutant B: omit `_generation` check in `_decide()` / final-device refresh -> an in-flight approval or poll from an
  /// earlier generation mutates `_claim` or triggers `familyProvider` refresh after replacement.
  testWidgets('#1190 P-05 generation guard: replacement clears presentation and discards stale polls, approvals, and device refreshes', (tester) async {
    final now = DateTime(2026, 11, 27, 6, 45);
    final exp = now.add(const Duration(minutes: 10)).toUtc().toIso8601String();
    var pairMintCount = 0;
    final gen2CreateGate = Completer<void>();
    final gen1PollGate = Completer<void>();
    final gen2ApproveGate = Completer<void>();
    var gen3ClaimReady = false;
    final approvedClaimIds = <String>[];

    final api = FakeApiClient({
      ...standardRoutes(),
      'POST /v1/devices/pair': (_) {
        pairMintCount += 1;
        if (pairMintCount == 1) {
          return {'code': '111111', 'expiresAt': exp};
        }
        if (pairMintCount == 2) {
          return FakeDeferred(
            gen2CreateGate.future.then((_) => {'code': '222222', 'expiresAt': exp}),
          );
        }
        return {'code': '333333', 'expiresAt': exp};
      },
      'GET /v1/devices/pair/111111/claim': (_) => FakeDeferred(
            gen1PollGate.future.then(
              (_) => {
                'claimId': 'claim-gen-1',
                'status': 'pending',
                'deviceName': 'Stale Gen1 Phone',
                'model': 'Old Model',
              },
            ),
          ),
      'GET /v1/devices/pair/222222/claim': (_) => {
            'claimId': 'claim-gen-2',
            'status': 'pending',
            'deviceName': 'Gen2 Phone',
            'model': 'Pixel 8',
          },
      'GET /v1/devices/pair/333333/claim': (_) => gen3ClaimReady
          ? {
              'claimId': 'claim-gen-3',
              'status': 'pending',
              'deviceName': 'Current Gen3 Phone',
              'model': 'Pixel 9',
            }
          : {'status': 'waiting'},
      'POST /v1/devices/pair/claims/claim-gen-1/approve': (_) {
        approvedClaimIds.add('claim-gen-1');
        return const {'status': 'approved'};
      },
      'POST /v1/devices/pair/claims/claim-gen-2/approve': (_) => FakeDeferred(
            gen2ApproveGate.future.then((_) {
              approvedClaimIds.add('claim-gen-2');
              return const {'status': 'approved'};
            }),
          ),
      'POST /v1/devices/pair/claims/claim-gen-3/approve': (_) {
        approvedClaimIds.add('claim-gen-3');
        return const {'status': 'approved'};
      },
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(api),
          p05PairEnabledProvider.overrideWithValue(true),
        ],
        child: MaterialApp(
          theme: AppTheme.light,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: PairingQrScreen(
            childId: 'child-1',
            childName: 'Alex',
            clock: () => now,
            onContinue: () {},
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.textContaining('111 · 111'), findsOneWidget);

    // Trigger Generation 1 poll (suspended in flight), then tap New code -> Generation 2 create suspends.
    await tester.pump(const Duration(seconds: 2));
    await tester.ensureVisible(find.byKey(const ValueKey('p05NewCodeButton')));
    await tester.tap(find.byKey(const ValueKey('p05NewCodeButton')));
    await tester.pump();

    // Pairing presentation is immediately cleared while replacement code is loading.
    expect(find.byKey(const ValueKey('p05QrCodeCard')), findsNothing);
    expect(find.textContaining('111 · 111'), findsNothing);
    expect(find.byKey(const ValueKey('p05ConfirmDeviceCard')), findsNothing);

    // Complete stale Gen1 poll while Gen2 create is still suspended, then complete Gen2 create.
    gen1PollGate.complete();
    await tester.pump(const Duration(milliseconds: 20));
    gen2CreateGate.complete();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.textContaining('222 · 222'), findsOneWidget);
    expect(find.textContaining('Stale Gen1 Phone'), findsNothing);
    expect(find.byKey(const ValueKey('p05ConfirmDeviceCard')), findsNothing);

    // Poll Gen2 -> shows Gen2 Phone -> tap Confirm (suspended on gen2ApproveGate), then immediately request New code (Gen3).
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.textContaining('Gen2 Phone'), findsOneWidget);

    await tester.scrollUntilVisible(find.byKey(const ValueKey('p05ConfirmLinkButton')), 200);
    await tester.tap(find.byKey(const ValueKey('p05ConfirmLinkButton')));
    await tester.pump();

    await tester.ensureVisible(find.byKey(const ValueKey('p05NewCodeButton')));
    await tester.tap(find.byKey(const ValueKey('p05NewCodeButton')));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.textContaining('333 · 333'), findsOneWidget);

    final familyReadsBefore = api.calls('GET', '/v1/families/me').length;
    gen2ApproveGate.complete();
    await tester.pump(const Duration(milliseconds: 50));

    // Stale Gen2 approval completion must NOT flip Gen3 into Approved or refresh familyProvider.
    expect(find.byKey(const ValueKey('p05ApprovedCard')), findsNothing);
    expect(find.byKey(const ValueKey('p05ConnectedCard')), findsNothing);
    expect(api.calls('GET', '/v1/families/me').length, familyReadsBefore);

    // Gen3 receives its own claim and approves cleanly.
    gen3ClaimReady = true;
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.textContaining('Current Gen3 Phone'), findsOneWidget);
    await tester.scrollUntilVisible(find.byKey(const ValueKey('p05ConfirmLinkButton')), 200);
    await tester.tap(find.byKey(const ValueKey('p05ConfirmLinkButton')));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));
    expect(approvedClaimIds.last, 'claim-gen-3');
    expect(approvedClaimIds.contains('claim-gen-1'), isFalse);
    expect(find.byKey(const ValueKey('p05ApprovedCard')), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  for (final cfg in [
    (locale: const Locale('en'), dark: false, size: const Size(390, 844), scale: 1.0),
    (locale: const Locale('en'), dark: true, size: const Size(390, 844), scale: 1.0),
    (locale: const Locale('ar'), dark: false, size: const Size(390, 844), scale: 1.0),
    (locale: const Locale('ar'), dark: true, size: const Size(390, 844), scale: 1.0),
    (locale: const Locale('en'), dark: false, size: const Size(320, 568), scale: 2.0),
    (locale: const Locale('en'), dark: true, size: const Size(320, 568), scale: 2.0),
    (locale: const Locale('ar'), dark: false, size: const Size(320, 568), scale: 2.0),
    (locale: const Locale('ar'), dark: true, size: const Size(320, 568), scale: 2.0),
  ]) {
    testWidgets(
      '#1179 P-05 Bureau matrix [${cfg.locale.languageCode} | ${cfg.dark ? "dark" : "light"} | ${cfg.size.width.toInt()}x${cfg.size.height.toInt()} | ${cfg.scale}x]',
      (tester) async {
        tester.view.physicalSize = cfg.size;
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        final now = DateTime(2026, 11, 26, 17, 45);
        final api = buildApi(expiresAt: now.add(const Duration(minutes: 10)));
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              apiClientProvider.overrideWithValue(api),
              p05PairEnabledProvider.overrideWithValue(true),
            ],
            child: MaterialApp(
              locale: cfg.locale,
              theme: AppTheme.light,
              darkTheme: AppTheme.dark,
              themeMode: cfg.dark ? ThemeMode.dark : ThemeMode.light,
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  textScaler: TextScaler.linear(cfg.scale),
                ),
                child: child!,
              ),
              home: PairingQrScreen(
                childId: 'child-1',
                childName: 'Alex',
                clock: () => now,
                onSkip: () {},
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));

        expect(tester.takeException(), isNull);
        expect(find.byKey(const ValueKey('p05QrCodeCard')), findsOneWidget);
      },
    );
  }
}
