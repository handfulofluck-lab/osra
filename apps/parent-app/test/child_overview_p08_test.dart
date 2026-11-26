import 'package:familyshield_parent/features/children/child_detail_screen.dart';
import 'package:familyshield_parent/features/children/child_overview_p08.dart';
import 'package:familyshield_parent/l10n/app_localizations.dart';
import 'package:familyshield_parent/providers/auth_provider.dart';
import 'package:familyshield_parent/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'fake_api_client.dart';

/// #1179 P-08 Child Overview tests.
///
/// Mutant checks:
/// - Removing `p08ChildOverviewEnabledProvider` gate breaks the fallback test.
/// - Showing `Switch device` for 1 device fails the single-device test.
/// - Re-introducing a `"Protected 81%"` badge or `"-12%"` delta fails the forbidden-copy assertions.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  Map<String, dynamic> buildFamily({
    required int deviceCount,
    int rulesVersion = 5,
    int? appliedRulesVersion = 5,
    String platform = 'android',
  }) {
    final reported = DateTime(2026, 11, 26, 12, 3).toUtc().toIso8601String();
    final devices = <Map<String, dynamic>>[
      for (var i = 0; i < deviceCount; i++)
        {
          'id': 'dev-${i + 1}',
          'childId': 'child-1',
          'platform': platform,
          'model': i == 0 ? 'Galaxy S23' : 'Pixel 8',
          'osVersion': platform == 'ios' ? '18.1' : '14',
          'status': 'online',
          'batteryPct': i == 0 ? 78 : 54,
          'lastSeen': reported,
          'setup': {
            'reportedAt': reported,
            'grants': <String, dynamic>{},
          },
        },
    ];
    final base = familyMeTwoChildren();
    return {
      ...base,
      'family': {
        ...(base['family'] as Map<String, dynamic>),
        'utcOffsetMinutes': 240,
      },
      'children': [
        {
          'id': 'child-1',
          'familyId': 'fam-1',
          'displayName': 'Alex',
          'birthYear': 2014,
          'screenTimeTodayMinutes': 45,
          'rulesVersion': rulesVersion,
          'appliedRulesVersion': appliedRulesVersion,
        },
      ],
      'devices': devices,
    };
  }

  FakeApiClient buildApi({
    int deviceCount = 1,
    int rulesVersion = 5,
    int? appliedRulesVersion = 5,
    String platform = 'android',
    List<String>? sentCommands,
    List<int>? bonusGrants,
    bool includeRulesAck = true,
    Map<String, dynamic> Function(RecordedRequest)? onCommand,
  }) {
    return FakeApiClient({
      ...standardRoutes(
        familyMe: buildFamily(
          deviceCount: deviceCount,
          rulesVersion: rulesVersion,
          appliedRulesVersion: appliedRulesVersion,
          platform: platform,
        ),
      ),
      'GET /v1/devices/dev-1/commands/history': (_) => {
            'items': includeRulesAck
                ? [
                    {
                      'id': 'cmd-rules-1',
                      'deviceId': 'dev-1',
                      'type': 'rules_updated',
                      'status': 'acked',
                      'createdAt': '2026-11-26T12:02:00Z',
                      'ackedAt': '2026-11-26T12:03:00Z',
                    },
                  ]
                : <Map<String, dynamic>>[],
          },
      'GET /v1/geofences/child-1': (_) => {
            'geofences': [
              {'id': 'g1', 'childId': 'child-1', 'label': 'Home', 'lat': 25.2, 'lng': 55.27, 'radiusM': 150},
              {'id': 'g2', 'childId': 'child-1', 'label': 'School', 'lat': 25.21, 'lng': 55.28, 'radiusM': 200},
            ],
          },
      'POST /v1/devices/dev-1/command': (req) {
        final cmd = (req.data as Map?)?['command']?.toString() ?? '';
        sentCommands?.add(cmd);
        return onCommand != null ? onCommand(req) : {'ok': true};
      },
      'POST /v1/controls/children/child-1/bonus': (req) {
        final mins = (req.data as Map?)?['minutes'] as int? ?? 0;
        bonusGrants?.add(mins);
        return {'ok': true};
      },
      'POST /v1/controls/children/child-1/pause': (_) => {'paused': true},
      'POST /v1/controls/children/child-1/resume': (_) => {'paused': false},
    });
  }

  GoRouter buildRouter(List<String> pushedRoutes) => GoRouter(
        initialLocation: '/child/child-1',
        routes: [
          GoRoute(
            path: '/child/:id',
            builder: (_, s) {
              if (s.uri.queryParameters['tab'] == 'location') {
                pushedRoutes.add(s.uri.toString());
                return const Scaffold(body: Text('LOCATION_DEST'));
              }
              return ChildDetailScreen(childId: s.pathParameters['id']!);
            },
          ),
          for (final sub in ['rules', 'social', 'commands', 'reports', 'searches', 'consent', 'pair'])
            GoRoute(
              path: '/child/:id/$sub',
              builder: (_, s) {
                pushedRoutes.add(s.uri.toString());
                return Scaffold(body: Text('DEST_$sub'));
              },
            ),
        ],
      );

  testWidgets('#1179 P-08 switch ON renders 8 tiles, proof line, no tabs, no forbidden badges, no Switch device for 1 device', (tester) async {
    final pushed = <String>[];
    final api = buildApi(deviceCount: 1, rulesVersion: 5, appliedRulesVersion: 5);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(api),
          p08ChildOverviewEnabledProvider.overrideWithValue(true),
        ],
        child: MaterialApp.router(
          theme: AppTheme.light,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          routerConfig: buildRouter(pushed),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(TabBar), findsNothing);
    expect(find.byKey(const ValueKey('p08TimeLeftCard')), findsOneWidget);
    expect(find.byKey(const ValueKey('p08NamedDevice')), findsOneWidget);
    // Only 1 device -> Switch device button must be absent.
    expect(find.byKey(const ValueKey('p08SwitchDeviceButton')), findsNothing);
    // Proof line shows Applied on Galaxy S23 at 16:03 (family UTC+4 clock from rules_updated ackedAt)
    final proof = tester.widget<Text>(find.byKey(const ValueKey('p08ProofLine'))).data ?? '';
    expect(proof, contains('Applied on'));
    expect(proof, contains('Galaxy S23'));
    expect(proof, contains('16:03'));
    // Forbidden elements from #1179: no "81%", no "-12%" / "−12%"
    expect(find.textContaining('81%'), findsNothing);
    expect(find.textContaining('12%'), findsNothing);

    // All 8 read-only tiles present.
    for (final id in ['dailyLimit', 'bedtime', 'apps', 'webFilter', 'places', 'social', 'devices', 'thisWeek']) {
      expect(find.byKey(ValueKey('p08Tile-$id')), findsOneWidget);
    }
  });

  testWidgets('#1179 P-08 switch OFF falls back to legacy 5-tab ChildDetailScreen', (tester) async {
    final api = buildApi(deviceCount: 1);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(api),
          p08ChildOverviewEnabledProvider.overrideWithValue(false),
        ],
        child: MaterialApp(
          theme: AppTheme.light,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const ChildDetailScreen(childId: 'child-1'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(TabBar), findsOneWidget);
    expect(find.byKey(const ValueKey('p08TimeLeftCard')), findsNothing);
  });

  testWidgets('#1179 P-08 shows Switch device when >1 device and switches active device', (tester) async {
    final api = buildApi(deviceCount: 2, rulesVersion: 5, appliedRulesVersion: 4);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(api),
          p08ChildOverviewEnabledProvider.overrideWithValue(true),
        ],
        child: MaterialApp(
          theme: AppTheme.light,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const ChildDetailScreen(childId: 'child-1'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Behind rules -> "Sent to phone" proof line
    expect(tester.widget<Text>(find.byKey(const ValueKey('p08ProofLine'))).data, 'Sent to phone');
    expect(find.byKey(const ValueKey('p08SwitchDeviceButton')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('p08SwitchDeviceButton')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('p08-device-option-dev-2')));
    await tester.pumpAndSettle();

    expect(tester.widget<Text>(find.byKey(const ValueKey('p08NamedDevice'))).data, contains('Pixel 8'));
  });

  testWidgets('#1179 P-08 Quick Actions send lock, ring/stop_ring, and +30 min bonus', (tester) async {
    final cmds = <String>[];
    final bonuses = <int>[];
    final api = buildApi(deviceCount: 1, sentCommands: cmds, bonusGrants: bonuses);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(api),
          p08ChildOverviewEnabledProvider.overrideWithValue(true),
        ],
        child: MaterialApp(
          theme: AppTheme.light,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const ChildDetailScreen(childId: 'child-1'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(find.byKey(const ValueKey('p08QuickAction-bonus30')), 200);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('p08QuickAction-lock')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('p08QuickAction-ring')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('p08QuickAction-ring')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('p08QuickAction-bonus30')));
    await tester.pumpAndSettle();

    expect(cmds, ['lock', 'ring', 'stop_ring']);
    expect(bonuses, [30]);
    expect(find.text('Pause internet'), findsOneWidget);
  });

  testWidgets('#1179 P-08 G6: iPhone child with no usage shows Not yet available on iPhone instead of made-up time left', (tester) async {
    final family = buildFamily(deviceCount: 1, platform: 'ios');
    (family['children'] as List<Map<String, dynamic>>)[0]['screenTimeTodayMinutes'] = 0;
    final api = FakeApiClient({
      ...standardRoutes(familyMe: family),
      'GET /v1/geofences/child-1': (_) => {'geofences': <Map<String, dynamic>>[]},
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(api),
          p08ChildOverviewEnabledProvider.overrideWithValue(true),
        ],
        child: MaterialApp(
          theme: AppTheme.light,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const ChildDetailScreen(childId: 'child-1'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      tester.widget<Text>(find.byKey(const ValueKey('p08TimeLeftHeadline'))).data,
      'Not yet available on iPhone',
    );
  });

  testWidgets('#1186 finding 1: Lock skips iOS devices and reports server refusals instead of Queued', (tester) async {
    final iosCmds = <String>[];
    final iosApi = buildApi(deviceCount: 1, platform: 'ios', sentCommands: iosCmds);
    await tester.pumpWidget(
      ProviderScope(
        key: UniqueKey(),
        overrides: [
          apiClientProvider.overrideWithValue(iosApi),
          p08ChildOverviewEnabledProvider.overrideWithValue(true),
        ],
        child: MaterialApp(
          theme: AppTheme.light,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const ChildDetailScreen(childId: 'child-1'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(find.byKey(const ValueKey('p08QuickAction-lock')), 200);
    await tester.tap(find.byKey(const ValueKey('p08QuickAction-lock')));
    await tester.pumpAndSettle();
    expect(iosCmds, isEmpty);
    expect(find.textContaining('Queued'), findsNothing);

    final refusedCmds = <String>[];
    final refusedApi = buildApi(
      deviceCount: 1,
      platform: 'android',
      sentCommands: refusedCmds,
      onCommand: (_) => {'published': false, 'status': 'failed', 'reason': 'device_admin_inactive'},
    );
    await tester.pumpWidget(
      ProviderScope(
        key: UniqueKey(),
        overrides: [
          apiClientProvider.overrideWithValue(refusedApi),
          p08ChildOverviewEnabledProvider.overrideWithValue(true),
        ],
        child: MaterialApp(
          theme: AppTheme.light,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const ChildDetailScreen(childId: 'child-1'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(find.byKey(const ValueKey('p08QuickAction-lock')), 200);
    await tester.tap(find.byKey(const ValueKey('p08QuickAction-lock')));
    await tester.pumpAndSettle();
    expect(refusedCmds, ['lock']);
    expect(find.textContaining('Queued'), findsNothing);
    expect(find.textContaining('Galaxy S23'), findsWidgets);
  });

  testWidgets('#1186 finding 2: proof line falls back to Sent to phone when no acked rules_updated command exists', (tester) async {
    final api = buildApi(deviceCount: 1, rulesVersion: 5, appliedRulesVersion: 5, includeRulesAck: false);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(api),
          p08ChildOverviewEnabledProvider.overrideWithValue(true),
        ],
        child: MaterialApp(
          theme: AppTheme.light,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const ChildDetailScreen(childId: 'child-1'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.widget<Text>(find.byKey(const ValueKey('p08ProofLine'))).data, 'Sent to phone');
  });

  testWidgets('#1186 finding 3: ChildDetailScreen honours ?tab=location even when P-08 switch is ON', (tester) async {
    final api = buildApi(deviceCount: 1);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(api),
          p08ChildOverviewEnabledProvider.overrideWithValue(true),
        ],
        child: MaterialApp(
          theme: AppTheme.light,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const ChildDetailScreen(childId: 'child-1', initialTab: ChildDetailScreen.locationTab),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(TabBar), findsOneWidget);
    expect(find.byKey(const ValueKey('p08TimeLeftCard')), findsNothing);
  });

  for (final cfg in [
    (locale: const Locale('en'), dark: false, size: const Size(390, 844), scale: 1.0),
    (locale: const Locale('ar'), dark: false, size: const Size(390, 844), scale: 1.0),
    (locale: const Locale('en'), dark: true, size: const Size(320, 568), scale: 2.0),
    (locale: const Locale('ar'), dark: true, size: const Size(320, 568), scale: 2.0),
  ]) {
    testWidgets(
      '#1179 P-08 Bureau matrix [${cfg.locale.languageCode} | ${cfg.dark ? "dark" : "light"} | ${cfg.size.width.toInt()}x${cfg.size.height.toInt()} | ${cfg.scale}x]',
      (tester) async {
        tester.view.physicalSize = cfg.size;
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        final api = buildApi(deviceCount: 2);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              apiClientProvider.overrideWithValue(api),
              p08ChildOverviewEnabledProvider.overrideWithValue(true),
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
              home: const ChildDetailScreen(childId: 'child-1'),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        expect(find.byKey(const ValueKey('p08TimeLeftCard')), findsOneWidget);
        expect(find.byKey(const ValueKey('p08Tile-dailyLimit')), findsOneWidget);
      },
    );
  }
}
