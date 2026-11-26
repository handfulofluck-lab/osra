import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:familyshield_parent/features/rules/bedtime_p11_screen.dart';
import 'package:familyshield_parent/features/rules/rules_editor_screen.dart';
import 'package:familyshield_parent/l10n/app_localizations.dart';
import 'package:familyshield_parent/providers/auth_provider.dart';
import 'package:familyshield_parent/theme/app_theme.dart';

import 'fake_api_client.dart';

Map<String, dynamic> _overview({String platform = 'android'}) => {
      'family': {'id': 'fam-1', 'name': 'Test Family'},
      'children': [
        {'id': 'child-1', 'displayName': 'Alex', 'birthYear': 2015},
      ],
      'devices': [
        {
          'id': 'dev-1',
          'childId': 'child-1',
          'platform': platform,
          'model': platform == 'ios' ? 'iPhone 15' : 'Galaxy S23',
          'rulesVersion': 2,
          'appliedRulesVersion': 2,
        },
      ],
      'openAlerts': <dynamic>[],
    };

Map<String, dynamic> _rules({
  String bedtimeStart = '21:30',
  String bedtimeEnd = '07:00',
  String schoolStart = '07:45',
  String schoolEnd = '14:30',
  List<int> schoolDays = const [1, 2, 3, 4, 5],
}) =>
    {
      'id': 'rule-1',
      'childId': 'child-1',
      'screenTime': {
        'dailyLimitMinutes': 120,
        'weekendLimitMinutes': 180,
        'bedtimeStart': bedtimeStart,
        'bedtimeEnd': bedtimeEnd,
        'schoolStart': schoolStart,
        'schoolEnd': schoolEnd,
        'schoolDays': schoolDays,
      },
      'webFilter': {
        'blockedCategories': <String>[],
        'allowedDomains': <String>[],
        'blockedDomains': <String>[],
      },
      'appRules': <dynamic>[],
      'routines': [
        {
          'id': 'rt-1',
          'name': 'Homework',
          'startTime': '16:00',
          'endTime': '17:30',
          'days': [1, 2, 3, 4],
          'blockedApps': <String>[],
          'allowedApps': <String>[],
        },
      ],
      'alwaysAllowedApps': <String>[],
    };

FakeApiClient _makeApi({
  String platform = 'android',
  Map<String, dynamic>? rules,
}) =>
    FakeApiClient({
      'GET /v1/family/me': (_) => _overview(platform: platform),
      'GET /v1/rules/child-1': (_) => rules ?? _rules(),
      'GET /v1/children/child-1/apps': (_) => {
            'apps': [
              {'packageId': 'com.samsung.android.spay', 'label': 'Samsung Pay'},
              {'packageId': 'com.google.android.apps.walletnfcrel', 'label': 'Google Wallet'},
            ],
            'reportedAt': '2026-11-26T12:00:00Z',
            'truncated': false,
          },
      'PATCH /v1/rules/child-1': (_) => {'ok': true},
      'POST /v1/controls/children/child-1/wind-down': (_) => {'ok': true},
    });

Widget _harness({
  required FakeApiClient api,
  required Widget home,
  Locale locale = const Locale('en'),
  ThemeMode themeMode = ThemeMode.light,
  double textScale = 1.0,
  bool p11Enabled = true,
}) {
  return ProviderScope(
    key: UniqueKey(),
    overrides: [
      apiClientProvider.overrideWithValue(api),
      p11BedtimeEnabledProvider.overrideWithValue(p11Enabled),
    ],
    child: MaterialApp(
      locale: locale,
      themeMode: themeMode,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: home,
    ),
  );
}

void main() {
  testWidgets(
      'P-11 renders routine cards, hides Skip tonight / +30 / 24h strip, and toggles bedtime off via start == end (G14)',
      (tester) async {
    final api = _makeApi();
    await tester.pumpWidget(_harness(api: api, home: const BedtimeP11Screen(childId: 'child-1')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('p11-bedtime-card')), findsOneWidget);

    // G14: no "Skip tonight", no "+30", no day chips inside the bedtime card.
    expect(find.textContaining('Skip tonight'), findsNothing);
    expect(find.textContaining('+30'), findsNothing);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('p11-bedtime-card')),
        matching: find.byType(FilterChip),
      ),
      findsNothing,
    );

    // Toggle bedtime OFF -> start == end on PATCH.
    await tester.tap(find.byKey(const ValueKey('p11-bedtime-switch')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('p11-bedtime-off')), findsOneWidget);

    // Scroll down to verify School hours and custom routine cards exist.
    await tester.scrollUntilVisible(find.byKey(const ValueKey('p11-school-card')), 150);
    expect(find.byKey(const ValueKey('p11-school-card')), findsOneWidget);
    await tester.scrollUntilVisible(find.byKey(const ValueKey('p11-routine-rt-1')), 150);
    expect(find.byKey(const ValueKey('p11-routine-rt-1')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('p11-save-button')));
    await tester.pumpAndSettle();
    final patches = api.requests.where((r) => r.method == 'PATCH' && r.path == '/v1/rules/child-1').toList();
    expect(patches, hasLength(1));
    final st = patches.single.body['screenTime'] as Map<String, dynamic>;
    expect(st['bedtimeEnd'], '21:30');
  });

  testWidgets('A27 payment-apps line shown for Android child and hidden for iPhone-only child',
      (tester) async {
    final androidApi = _makeApi(platform: 'android');
    await tester.pumpWidget(_harness(api: androidApi, home: const BedtimeP11Screen(childId: 'child-1')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('p11-bedtime-blocks-payments')), findsOneWidget);
    expect(find.byKey(const ValueKey('p11-add-payment-app')), findsOneWidget);

    final iosApi = _makeApi(platform: 'ios');
    await tester.pumpWidget(_harness(api: iosApi, home: const BedtimeP11Screen(childId: 'child-1')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('p11-bedtime-blocks-payments')), findsNothing);
    expect(find.byKey(const ValueKey('p11-add-payment-app')), findsNothing);
  });

  testWidgets('A4 wind-down button on bedtime card POSTs wind-down minutes', (tester) async {
    final api = _makeApi();
    await tester.pumpWidget(_harness(api: api, home: const BedtimeP11Screen(childId: 'child-1')));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(find.byKey(const ValueKey('p11-wind-down-button')), 100);
    await tester.tap(find.byKey(const ValueKey('p11-wind-down-button')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('p11-wind-down-15')));
    await tester.pumpAndSettle();

    final posts = api.requests
        .where((r) => r.method == 'POST' && r.path == '/v1/controls/children/child-1/wind-down')
        .toList();
    expect(posts, hasLength(1));
    expect(posts.single.body['minutes'], 15);
  });

  testWidgets('Feature switch routes RulesEditorScreen(initialTab: 3) between P-11 and legacy',
      (tester) async {
    final api = _makeApi();

    await tester.pumpWidget(_harness(
      api: api,
      p11Enabled: false,
      home: const RulesEditorScreen(childId: 'child-1', initialTab: 3),
    ));
    await tester.pumpAndSettle();
    expect(find.byType(BedtimeP11Screen), findsNothing);
    expect(find.byKey(const ValueKey('rules-save-button')), findsOneWidget);

    await tester.pumpWidget(_harness(
      api: api,
      p11Enabled: true,
      home: const RulesEditorScreen(childId: 'child-1', initialTab: 3),
    ));
    await tester.pumpAndSettle();
    expect(find.byType(BedtimeP11Screen), findsOneWidget);
    expect(find.byKey(const ValueKey('p11-save-button')), findsOneWidget);
  });

  testWidgets('Bureau matrix: zero overflow across EN/AR, light/dark, 390x844 @ 1x and 320x568 @ 2x',
      (tester) async {
    final api = _makeApi();
    final configs = [
      (const Locale('en'), ThemeMode.light, const Size(390, 844), 1.0),
      (const Locale('en'), ThemeMode.dark, const Size(320, 568), 2.0),
      (const Locale('ar'), ThemeMode.light, const Size(390, 844), 1.0),
      (const Locale('ar'), ThemeMode.dark, const Size(320, 568), 2.0),
    ];

    for (final (locale, mode, size, scale) in configs) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_harness(
        api: api,
        locale: locale,
        themeMode: mode,
        textScale: scale,
        home: const BedtimeP11Screen(childId: 'child-1'),
      ));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'Failed on $locale $mode $size @ ${scale}x');
    }
  });
}
