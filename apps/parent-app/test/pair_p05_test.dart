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

/// #1179 P-05 Pair device tests (★0, A10).
///
/// Mutant checks:
/// - Removing `p05PairEnabledProvider` gate breaks the fallback test.
/// - Re-introducing OS chooser (`Android` / `iPhone`) or copy-code button fails the forbidden-element assertions.
/// - Skipping device-name confirmation (`A10`) fails the claim approval test.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  FakeApiClient buildApi({
    String code = '482913',
    DateTime? expiresAt,
    Map<String, dynamic>? claimResponse,
    List<String>? approvedClaims,
  }) {
    final exp = (expiresAt ?? DateTime.now().add(const Duration(minutes: 10))).toUtc().toIso8601String();
    return FakeApiClient({
      ...standardRoutes(),
      'POST /v1/devices/pair': (_) => {'code': code, 'expiresAt': exp},
      'GET /v1/devices/pair/$code/claim': (_) =>
          claimResponse ?? {'status': 'waiting'},
      'POST /v1/devices/pair/claims/claim-1/approve': (_) {
        approvedClaims?.add('claim-1');
        return {'ok': true};
      },
      'POST /v1/devices/pair/claims/claim-1/deny': (_) => {'ok': true},
    });
  }

  testWidgets('#1179 P-05 switch ON shows QR + code, waiting line, no OS chooser, no copy-code button, and confirms device name (A10)', (tester) async {
    final approved = <String>[];
    final now = DateTime(2026, 11, 26, 17, 45);
    final api = buildApi(
      code: '482913',
      expiresAt: now.add(const Duration(minutes: 10)),
      claimResponse: {
        'claimId': 'claim-1',
        'status': 'pending',
        'model': 'Galaxy A54',
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
            onSkip: () {},
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byKey(const ValueKey('p05QrCodeCard')), findsOneWidget);
    expect(find.byKey(const ValueKey('p05QrImage')), findsOneWidget);
    expect(find.byKey(const ValueKey('p05CodeText')), findsOneWidget);
    expect(find.textContaining('482 · 913'), findsOneWidget);
    expect(find.byKey(const ValueKey('p05ExpiryPill')), findsOneWidget);
    expect(find.byKey(const ValueKey('p05NewCodeButton')), findsOneWidget);
    expect(find.byKey(const ValueKey('p05SendInstallLinkButton')), findsOneWidget);
    expect(find.byKey(const ValueKey('p05SkipButton')), findsOneWidget);

    // Forbidden per #1179 P-05: no OS chooser, no copy-code button.
    expect(find.text('Android'), findsNothing);
    expect(find.text('iPhone'), findsNothing);
    expect(find.text('Copy code'), findsNothing);

    // Trigger 2-second claim poll -> shows device name confirmation card (A10).
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byKey(const ValueKey('p05ConfirmDeviceCard')), findsOneWidget);
    expect(find.textContaining('Galaxy A54'), findsOneWidget);

    await tester.scrollUntilVisible(find.byKey(const ValueKey('p05ConfirmLinkButton')), 200);
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('p05ConfirmLinkButton')));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));

    expect(approved, ['claim-1']);
    expect(find.byKey(const ValueKey('p05ConnectedCard')), findsOneWidget);
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

  for (final cfg in [
    (locale: const Locale('en'), dark: false, size: const Size(390, 844), scale: 1.0),
    (locale: const Locale('ar'), dark: false, size: const Size(390, 844), scale: 1.0),
    (locale: const Locale('en'), dark: true, size: const Size(320, 568), scale: 2.0),
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
