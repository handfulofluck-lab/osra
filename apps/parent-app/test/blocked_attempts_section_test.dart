import 'package:familyshield_parent/api/models.dart';
import 'package:familyshield_parent/features/alerts/alert_detail_screen.dart';
import 'package:familyshield_parent/l10n/app_localizations.dart';
import 'package:familyshield_parent/providers/auth_provider.dart';
import 'package:familyshield_parent/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_api_client.dart';

Alert _blockedAlert({
  required String category,
  required List<Map<String, dynamic>> attempts,
  String? kind,
  int? attemptCount,
}) =>
    Alert(
      id: 'alert-blk-1',
      childId: 'child-1',
      deviceId: 'dev-1',
      severity: 'medium',
      category: category,
      title: 'Blocked',
      body: '',
      attemptCount: attemptCount ?? attempts.length,
      createdAt: DateTime.utc(2026, 11, 26, 14, 5),
      metadata: {
        'blockGroup': {
          if (kind != null) 'kind': kind,
          'attempts': attempts,
        },
      },
    );

Widget _harness({
  required Alert alert,
  Locale locale = const Locale('en'),
  ThemeMode themeMode = ThemeMode.light,
  double textScale = 1.0,
}) {
  final api = FakeApiClient(standardRoutes());
  return ProviderScope(
    key: UniqueKey(),
    overrides: [
      apiClientProvider.overrideWithValue(api),
    ],
    child: MaterialApp(
      locale: locale,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: themeMode,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: AlertDetailScreen(
        alertId: alert.id,
        initialAlert: alert,
        nowProvider: () => DateTime.utc(2026, 11, 26, 14, 10),
      ),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  // Mutant: removing `parsed.sort((a, b) => b.at.compareTo(a.at))` fails the newest-first order check.
  testWidgets('Web grouped alert lists all 5 attempts newest-first with site names when present',
      (tester) async {
    final alert = _blockedAlert(
      category: 'web_threat',
      kind: 'web',
      attempts: [
        {'at': '2026-11-26T14:01:00Z', 'site': 'first.example'},
        {'at': '2026-11-26T14:05:00Z', 'site': 'newest.example'},
        {'at': '2026-11-26T14:03:00Z', 'site': 'middle.example'},
        {'at': '2026-11-26T14:02:00Z', 'site': 'second.example'},
        {'at': '2026-11-26T14:04:00Z', 'site': 'fourth.example'},
      ],
    );

    await tester.pumpWidget(_harness(alert: alert));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('blockedAttemptsCard')), findsOneWidget);
    for (var i = 0; i < 5; i++) {
      expect(find.byKey(ValueKey('blockedAttemptRow-$i')), findsOneWidget);
    }
    // Newest entry must be row 0, oldest row 4.
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('blockedAttemptRow-0')),
        matching: find.textContaining('newest.example'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('blockedAttemptRow-4')),
        matching: find.textContaining('first.example'),
      ),
      findsOneWidget,
    );
  });

  // Mutant: dropping `blockedAttemptSiteFallback` leaves empty label when SITE_NAMES_ENABLED is off.
  testWidgets('Web grouped alert without site names renders "Blocked site" fallback per entry',
      (tester) async {
    final alert = _blockedAlert(
      category: 'web_threat',
      kind: 'web',
      attempts: [
        {'at': '2026-11-26T14:05:00Z'},
        {'at': '2026-11-26T14:02:00Z'},
      ],
    );

    await tester.pumpWidget(_harness(alert: alert));
    await tester.pumpAndSettle();

    expect(find.text('Blocked site'), findsNWidgets(2));
  });

  // Mutant: ignoring `kind == 'app'` renders "Blocked site" instead of app name / "Blocked app".
  testWidgets('App grouped alert renders app name when present and "Blocked app" when omitted',
      (tester) async {
    final alert = _blockedAlert(
      category: 'app_blocked',
      kind: 'app',
      attempts: [
        {'at': '2026-11-26T14:05:00Z', 'app': 'TikTok'},
        {'at': '2026-11-26T14:02:00Z'},
      ],
    );

    await tester.pumpWidget(_harness(alert: alert));
    await tester.pumpAndSettle();

    expect(find.textContaining('TikTok'), findsAtLeastNWidgets(1));
    expect(find.text('Blocked app'), findsOneWidget);
  });

  // Mutant: removing `isCapped` caption fails `blockedAttemptsCapNote` when attemptCount > entries.length.
  testWidgets('Capped attempts list shows "Showing 50 of 73" caption', (tester) async {
    final attempts = List.generate(
      50,
      (i) => {'at': DateTime.utc(2026, 11, 26, 13, i).toIso8601String()},
    );
    final alert = _blockedAlert(
      category: 'web_threat',
      kind: 'web',
      attempts: attempts,
      attemptCount: 73,
    );

    await tester.pumpWidget(_harness(alert: alert));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('blockedAttemptsCapNote')), findsOneWidget);
    expect(find.textContaining('50'), findsWidgets);
    expect(find.textContaining('73'), findsWidgets);
  });

  // Mutant: rendering `blockedAttemptsCard` unconditionally fails this non-grouped alert check.
  testWidgets('Non-grouped alert without blockGroup.attempts hides BlockedAttemptsSection',
      (tester) async {
    final alert = Alert(
      id: 'alert-plain',
      childId: 'child-1',
      deviceId: 'dev-1',
      severity: 'low',
      category: 'web_threat',
      title: 'Blocked site',
      body: '',
      createdAt: DateTime.utc(2026, 11, 26, 14, 5),
      metadata: const {},
    );

    await tester.pumpWidget(_harness(alert: alert));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('blockedAttemptsCard')), findsNothing);
  });

  // Mutant: overflow at 320px / 200% in EN or AR fails `takeException() == null`.
  testWidgets('Zero overflow at 320x568 @ 2.0x in EN and AR', (tester) async {
    final alert = _blockedAlert(
      category: 'web_threat',
      kind: 'web',
      attempts: [
        {'at': '2026-11-26T14:05:00Z', 'site': 'very-long-blocked-domain.example.com'},
        {'at': '2026-11-26T14:02:00Z'},
      ],
      attemptCount: 12,
    );

    for (final locale in const [Locale('en'), Locale('ar')]) {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_harness(
        alert: alert,
        locale: locale,
        textScale: 2.0,
      ));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.byKey(const ValueKey('blockedAttemptsCard')), 150);
      expect(tester.takeException(), isNull, reason: 'Overflow in $locale at 320x568 @ 2x');
      expect(find.byKey(const ValueKey('blockedAttemptsCard')), findsOneWidget);
    }
  });
}
