import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:familyshield_parent/api/models.dart';
import 'package:familyshield_parent/app.dart' show appRoutes;
import 'package:familyshield_parent/features/children/child_apps_list.dart';
import 'package:familyshield_parent/features/children/child_platform.dart';
import 'package:familyshield_parent/features/children/iphone_app_details_card.dart';
import 'package:familyshield_parent/features/reports/reports_screen.dart';
import 'package:familyshield_parent/features/reports/usage_history_screen.dart';
import 'package:familyshield_parent/l10n/l10n.dart';
import 'package:familyshield_parent/providers/auth_provider.dart';

import 'fake_api_client.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Device makeDevice(String id, String platform, {String childId = 'child-1'}) => Device(
        id: id,
        childId: childId,
        platform: platform,
        model: platform == 'ios' ? 'iPhone 15' : 'Pixel 8',
        osVersion: platform == 'ios' ? '18' : '15',
        status: 'online',
        batteryPct: 85,
      );

  Map<String, dynamic> deviceJson({
    required String id,
    required String childId,
    required String platform,
    String? model,
    List<Map<String, dynamic>>? groups,
  }) =>
      {
        'id': id,
        'childId': childId,
        'platform': platform,
        'model': model ?? (platform == 'ios' ? 'iPhone 15' : 'Pixel 8'),
        'osVersion': platform == 'ios' ? '18' : '15',
        'status': 'online',
        'batteryPct': 85,
        'lastSeen': DateTime.now().toUtc().toIso8601String(),
        if (groups != null)
          'setup': {
            'reportedAt': '2026-11-24T10:00:00.000Z',
            'features': <String, String>{},
            'missing': <String>[],
            'groups': groups,
          },
      };

  Map<String, dynamic> familyJson({
    required List<Map<String, dynamic>> children,
    required List<Map<String, dynamic>> devices,
  }) =>
      {
        'family': {
          'id': 'fam-1',
          'name': 'QA Family',
          'region': 'US',
          'utcOffsetMinutes': 240,
          'createdAt': DateTime.now().toUtc().toIso8601String(),
        },
        'parent': {
          'id': 'par-1',
          'familyId': 'fam-1',
          'email': 'qa@osratech.com',
          'displayName': 'QA Parent',
          'role': 'owner',
          'mfaEnabled': false,
        },
        'children': children,
        'devices': devices,
      };

  Map<String, dynamic> childJson({
    required String id,
    required String displayName,
    int screenTimeTodayMinutes = 0,
    int birthYear = 2015,
  }) =>
      {
        'id': id,
        'familyId': 'fam-1',
        'displayName': displayName,
        'birthYear': birthYear,
        'screenTimeTodayMinutes': screenTimeTodayMinutes,
      };

  Future<void> pumpRoute(
    WidgetTester tester,
    FakeApiClient api, {
    required String initialLocation,
    Size size = const Size(393, 852),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    final router = GoRouter(
      initialLocation: initialLocation,
      routes: appRoutes,
    );
    addTearDown(() {
      router.dispose();
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [apiClientProvider.overrideWithValue(api)],
        child: MaterialApp.router(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          routerConfig: router,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('#1046 child_platform predicates', () {
    test('unpaired child (devices: []) has isIphoneOnlyChild == false', () {
      const devices = <Device>[];
      // Mutant: omitting `devices.isNotEmpty` in `isIphoneOnlyChild` would make `every(...)`
      // vacuously return `true` for an unpaired child, misclassifying empty/null devices as iPhone.
      expect(isIphoneOnlyChild(devices), isFalse);
      expect(hasIphoneDevice(devices), isFalse);
      expect(hasAndroidDevice(devices), isFalse);
    });

    test('iPhone-only child has isIphoneOnlyChild == true', () {
      final devices = [makeDevice('dev-ios', 'ios')];
      // Mutant: reading `platform == 'iOS'` (wrong case) or returning `false` breaks iPhone detection.
      expect(isIphoneOnlyChild(devices), isTrue);
      expect(hasIphoneDevice(devices), isTrue);
      expect(hasAndroidDevice(devices), isFalse);
    });

    test('Android-only child has isIphoneOnlyChild == false', () {
      final devices = [makeDevice('dev-and', 'android')];
      // Mutant: returning `true` for any paired device would hide Android screen time and apps.
      expect(isIphoneOnlyChild(devices), isFalse);
      expect(hasIphoneDevice(devices), isFalse);
      expect(hasAndroidDevice(devices), isTrue);
    });

    test('mixed-device child (iPhone + Android) has isIphoneOnlyChild == false', () {
      final devices = [makeDevice('dev-ios', 'ios'), makeDevice('dev-and', 'android')];
      // Mutant: using `any((d) => d.platform == 'ios')` instead of `every(...)` would hide the
      // Android device's screen time and app list for a mixed-device child.
      expect(isIphoneOnlyChild(devices), isFalse);
      expect(hasIphoneDevice(devices), isTrue);
      expect(hasAndroidDevice(devices), isTrue);
    });
  });

  group('#1046 iPhone-only child empty states', () {
    testWidgets('iPhone-only child Dashboard card shows iPhone line and daily limit without 0 min bar', (tester) async {
      final api = FakeApiClient({
        ...standardRoutes(
          familyMe: familyJson(
            children: [childJson(id: 'child-1', displayName: 'Omar', screenTimeTodayMinutes: 0)],
            devices: [deviceJson(id: 'dev-ios', childId: 'child-1', platform: 'ios')],
          ),
        ),
        'GET /v1/rules/child-1': (_) => ruleSetPayload('child-1'),
      });

      await pumpRoute(tester, api, initialLocation: '/');

      // Mutant: falling through to the Android screen-time branch renders `0 / 120 min` and a
      // `LinearProgressIndicator` instead of `iphoneScreenTime-child-1` and `iphoneDailyLimit-child-1`.
      expect(find.byKey(const ValueKey('iphoneScreenTime-child-1')), findsOneWidget);
      expect(find.text('Screen time: shown on \u2068Omar\u2069\'s iPhone'), findsOneWidget);
      expect(find.byKey(const ValueKey('iphoneDailyLimit-child-1')), findsOneWidget);
      expect(find.text('Limit 2 h a day'), findsOneWidget);
      expect(find.byIcon(Icons.phone_iphone), findsOneWidget);

      // Mutant: keeping the numeric bar alongside the iPhone copy would leave `0 / 120 min` or
      // `LinearProgressIndicator` visible on the card.
      expect(find.text('0 / 120 min'), findsNothing);
      expect(find.text('0 min'), findsNothing);
      expect(find.byType(LinearProgressIndicator), findsNothing);
    });

    testWidgets('iPhone-only child profile Overview shows iPhone screen-time line and daily limit', (tester) async {
      final api = FakeApiClient({
        ...standardRoutes(
          familyMe: familyJson(
            children: [childJson(id: 'child-1', displayName: 'Omar', screenTimeTodayMinutes: 0)],
            devices: [deviceJson(id: 'dev-ios', childId: 'child-1', platform: 'ios')],
          ),
        ),
        'GET /v1/rules/child-1': (_) => ruleSetPayload('child-1'),
        'GET /v1/devices/dev-ios/commands/history': (_) => {'items': <dynamic>[]},
      });

      await pumpRoute(tester, api, initialLocation: '/child/child-1');

      // Mutant: omitting the `if (iphoneOnly)` block on `_OverviewTab` drops the profile card
      // and leaves the daily limit invisible on the child profile.
      final cardFinder = find.byKey(const ValueKey('childProfileIphoneScreenTimeCard'));
      expect(cardFinder, findsOneWidget);
      expect(find.byKey(const ValueKey('childProfileIphoneScreenTime')), findsOneWidget);
      expect(find.text('Screen time: shown on \u2068Omar\u2069\'s iPhone'), findsOneWidget);
      expect(find.byKey(const ValueKey('childProfileDailyLimit')), findsOneWidget);
      expect(find.text('Limit 2 h a day'), findsOneWidget);

      final card = tester.widget<Card>(cardFinder);
      final colors = Theme.of(tester.element(cardFinder)).colorScheme;
      // Mutant: styling the card with `errorContainer` instead of `surfaceContainer` frames an
      // Apple platform rule as a fault.
      expect(card.color, colors.surfaceContainer);
      expect(find.byIcon(Icons.phone_iphone), findsOneWidget);
    });

    testWidgets(
      'iPhone-only child Apps tab shows neutral IphoneAppDetailsCard, opens 3-step How it works sheet, and hides per-app list even with legacy appRules',
      (tester) async {
        final api = FakeApiClient({
          ...standardRoutes(
            familyMe: familyJson(
              children: [childJson(id: 'child-1', displayName: 'Omar', screenTimeTodayMinutes: 0)],
              devices: [deviceJson(id: 'dev-ios', childId: 'child-1', platform: 'ios')],
            ),
          ),
          // Legacy Android-style `appRules` still present on the child's rule set.
          'GET /v1/rules/child-1': (_) => ruleSetPayload('child-1'),
          'GET /v1/devices/dev-ios/apps': (_) => installedAppsPayload(
                apps: [installedAppJson('com.example.game', 'Game')],
              ),
        });

        await pumpRoute(tester, api, initialLocation: '/child/child-1');

        await tester.tap(find.text('Apps'));
        await tester.pumpAndSettle();

        // Mutant: showing `ChildAppsList` or iterating `ruleSet.appRules` when `iphoneOnly` is true
        // would expose per-app rows (`Game`) and `showAppInsightSheet` on an iPhone-only child.
        expect(find.byType(IphoneAppDetailsCard), findsOneWidget);
        expect(find.byKey(const ValueKey('appsTabIphoneSetupCard')), findsOneWidget);
        expect(find.byKey(const ValueKey('iphoneAppDetailsIcon')), findsOneWidget);
        expect(find.byIcon(Icons.phone_iphone), findsOneWidget);
        expect(find.byIcon(Icons.warning_amber), findsNothing);
        expect(find.byIcon(Icons.error_outline), findsNothing);

        final cardFinder = find.byKey(const ValueKey('iphoneAppDetailsCard'));
        final card = tester.widget<Card>(cardFinder);
        final colors = Theme.of(tester.element(cardFinder)).colorScheme;
        // Mutant: using warning/error container colour instead of `surfaceContainer` fails here.
        expect(card.color, colors.surfaceContainer);

        expect(find.byType(ChildAppsList), findsNothing);
        expect(find.byKey(const ValueKey('appsTabManageAppsButton')), findsNothing);
        expect(find.text('Game'), findsNothing);
        expect(api.calls('GET', '/v1/insights/apps'), isEmpty);

        // Open the 3-step "How it works" modal sheet.
        await tester.tap(find.byKey(const ValueKey('iphoneHowItWorksButton')));
        await tester.pumpAndSettle();

        // Mutant: removing the sheet or dropping any of the 3 steps breaks the modal assertions.
        expect(find.byKey(const ValueKey('iphoneHowItWorksSheet')), findsOneWidget);
        expect(find.text('How app control works on iPhone'), findsOneWidget);
        expect(find.text('1.'), findsOneWidget);
        expect(find.text('2.'), findsOneWidget);
        expect(find.text('3.'), findsOneWidget);
        expect(
          find.text('Open OSRA on \u2068Omar\u2069\'s iPhone and group the apps you want to manage.'),
          findsOneWidget,
        );
        expect(
          find.text('Each app group appears in OSRA on your phone so you can block or allow it anytime.'),
          findsOneWidget,
        );
        expect(
          find.text('To check minutes used per app, open Settings > Screen Time on \u2068Omar\u2069\'s iPhone.'),
          findsOneWidget,
        );

        await tester.tap(find.byKey(const ValueKey('iphoneHowItWorksClose')));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('iphoneHowItWorksSheet')), findsNothing);
      },
    );

    testWidgets('iPhone-only child Reports screen shows IphoneAppDetailsCard and never 0 min or No app usage recorded', (tester) async {
      final api = FakeApiClient({
        ...standardRoutes(
          familyMe: familyJson(
            children: [childJson(id: 'child-1', displayName: 'Omar', screenTimeTodayMinutes: 0)],
            devices: [deviceJson(id: 'dev-ios', childId: 'child-1', platform: 'ios')],
          ),
        ),
        'GET /v1/reports/summary': (_) => {
              'totalAppMinutes': 0,
              'topApps': <dynamic>[],
              'urlVisits': 0,
              'topBlockedDomains': <dynamic>[],
              'socialConcerns': 0,
              'calls': 0,
              'sms': 0,
            },
      });

      await pumpRoute(tester, api, initialLocation: '/child/child-1/reports');

      // Mutant: rendering `_UsageSection` or `noActivityDays` when `iphoneOnly` is true shows
      // `0 min` / `No app usage recorded` / `No activity` instead of `IphoneAppDetailsCard`.
      expect(find.byType(IphoneAppDetailsCard), findsOneWidget);
      expect(find.text('App details stay on \u2068Omar\u2069\'s iPhone'), findsOneWidget);
      expect(find.textContaining('0 min'), findsNothing);
      expect(find.text('No app usage recorded'), findsNothing);
      expect(find.text('No activity in the last 7 days'), findsNothing);
    });

    testWidgets('iPhone-only child Usage History screen shows IphoneAppDetailsCard and never 0 min or empty usage text', (tester) async {
      final api = FakeApiClient({
        ...standardRoutes(
          familyMe: familyJson(
            children: [childJson(id: 'child-1', displayName: 'Omar', screenTimeTodayMinutes: 0)],
            devices: [deviceJson(id: 'dev-ios', childId: 'child-1', platform: 'ios')],
          ),
        ),
        'GET /v1/reports/usage': (_) => {
              'childId': 'child-1',
              'days': 7,
              'totalMinutes': 0,
              'series': [
                {'day': '2026-11-24', 'minutes': 0},
              ],
            },
        'GET /v1/reports/web': (_) => {'items': <dynamic>[]},
      });

      await pumpRoute(tester, api, initialLocation: '/child/child-1/history');

      // Mutant: skipping the `if (isIphoneOnlyChild(devices))` guard in `_UsageSection` renders
      // `No screen time recorded` or `0 min` bars instead of `IphoneAppDetailsCard`.
      expect(find.byType(IphoneAppDetailsCard), findsOneWidget);
      expect(find.text('App details stay on \u2068Omar\u2069\'s iPhone'), findsOneWidget);
      expect(find.textContaining('0 min'), findsNothing);
      expect(find.textContaining('No screen time recorded'), findsNothing);
      expect(find.text('No app usage recorded'), findsNothing);
      expect(find.byType(UsageBar), findsNothing);
    });
  });

  group('#1046 Android-only child unchanged behaviour', () {
    testWidgets('Android-only child Dashboard card keeps 45 / 120 min and LinearProgressIndicator', (tester) async {
      final api = FakeApiClient({
        ...standardRoutes(
          familyMe: familyJson(
            children: [childJson(id: 'child-1', displayName: 'Sam', screenTimeTodayMinutes: 45)],
            devices: [deviceJson(id: 'dev-and', childId: 'child-1', platform: 'android')],
          ),
        ),
        'GET /v1/rules/child-1': (_) => ruleSetPayload('child-1'),
      });

      await pumpRoute(tester, api, initialLocation: '/');

      // Mutant: flipping the `iphoneOnly` branch condition hides the Android numeric bar.
      expect(find.text('45 / 120 min'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(find.byKey(const ValueKey('iphoneScreenTime-child-1')), findsNothing);
    });

    testWidgets('Android-only child Apps tab keeps ChildAppsList', (tester) async {
      final api = FakeApiClient({
        ...standardRoutes(
          familyMe: familyJson(
            children: [childJson(id: 'child-1', displayName: 'Sam', screenTimeTodayMinutes: 45)],
            devices: [deviceJson(id: 'dev-and', childId: 'child-1', platform: 'android')],
          ),
        ),
        'GET /v1/rules/child-1': (_) => ruleSetPayload('child-1'),
        'GET /v1/devices/dev-and/apps': (_) => installedAppsPayload(
              apps: [installedAppJson('com.example.game', 'Game')],
            ),
      });

      await pumpRoute(tester, api, initialLocation: '/child/child-1');

      await tester.tap(find.text('Apps'));
      await tester.pumpAndSettle();

      // Mutant: guarding `ChildAppsList` with `false` or misclassifying Android breaks this.
      expect(find.byType(ChildAppsList), findsOneWidget);
      expect(find.byKey(const ValueKey('childAppsList')), findsOneWidget);
      expect(find.byType(IphoneAppDetailsCard), findsNothing);
    });

    testWidgets('Android-only child Reports screen keeps app usage section and TopAppsChart', (tester) async {
      final api = FakeApiClient({
        ...standardRoutes(
          familyMe: familyJson(
            children: [childJson(id: 'child-1', displayName: 'Sam', screenTimeTodayMinutes: 45)],
            devices: [deviceJson(id: 'dev-and', childId: 'child-1', platform: 'android')],
          ),
        ),
        'GET /v1/reports/summary': (_) => {
              'totalAppMinutes': 140,
              'topApps': [
                {'packageId': 'com.example.game', 'name': 'Game', 'minutes': 90},
                {'packageId': 'com.example.video', 'name': 'Video', 'minutes': 50},
              ],
              'urlVisits': 12,
              'topBlockedDomains': <dynamic>[],
              'socialConcerns': 0,
              'calls': 0,
              'sms': 0,
            },
      });

      await pumpRoute(tester, api, initialLocation: '/child/child-1/reports');

      // Mutant: showing `IphoneAppDetailsCard` for Android children hides `TopAppsChart` and `App usage`.
      expect(find.text('App usage'), findsOneWidget);
      expect(find.byType(TopAppsChart), findsOneWidget);
      expect(find.byType(IphoneAppDetailsCard), findsNothing);
    });
  });

  group('#1046 mixed family and mixed-device child', () {
    testWidgets('mixed family Dashboard renders iPhone-only child and Android-only child independently by platform', (tester) async {
      final api = FakeApiClient({
        ...standardRoutes(
          familyMe: familyJson(
            children: [
              childJson(id: 'child-1', displayName: 'Omar', screenTimeTodayMinutes: 0),
              childJson(id: 'child-2', displayName: 'Sam', screenTimeTodayMinutes: 45),
            ],
            devices: [
              deviceJson(id: 'dev-ios', childId: 'child-1', platform: 'ios'),
              deviceJson(id: 'dev-and', childId: 'child-2', platform: 'android'),
            ],
          ),
        ),
        'GET /v1/rules/child-1': (_) => ruleSetPayload('child-1'),
        'GET /v1/rules/child-2': (_) => ruleSetPayload('child-2'),
      });

      await pumpRoute(tester, api, initialLocation: '/');

      // Mutant: checking `overview.devices` instead of `overview.devicesFor(child.id)` would
      // either treat both children as iPhone-only or neither as iPhone-only.
      expect(find.byKey(const ValueKey('iphoneScreenTime-child-1')), findsOneWidget);
      expect(find.text('Screen time: shown on \u2068Omar\u2069\'s iPhone'), findsOneWidget);
      expect(find.byKey(const ValueKey('iphoneDailyLimit-child-1')), findsOneWidget);
      expect(find.text('Limit 2 h a day'), findsOneWidget);

      expect(find.byKey(const ValueKey('iphoneScreenTime-child-2')), findsNothing);
      expect(find.text('45 / 120 min'), findsOneWidget);
      // Mutant: averaging Omar's 0 min into Sam's 45 min would render `22 / 120 min` or `23 / 120 min`,
      // and rendering a progress bar for Omar would produce 2 `LinearProgressIndicator` widgets.
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
    });

    testWidgets('mixed-device child (iPhone + Android) keeps Android screen-time bar on Dashboard', (tester) async {
      final api = FakeApiClient({
        ...standardRoutes(
          familyMe: familyJson(
            children: [childJson(id: 'child-1', displayName: 'Omar', screenTimeTodayMinutes: 45)],
            devices: [
              deviceJson(id: 'dev-ios', childId: 'child-1', platform: 'ios'),
              deviceJson(id: 'dev-and', childId: 'child-1', platform: 'android'),
            ],
          ),
        ),
        'GET /v1/rules/child-1': (_) => ruleSetPayload('child-1'),
      });

      await pumpRoute(tester, api, initialLocation: '/');

      // Mutant: using `hasIphoneDevice` instead of `isIphoneOnlyChild` on Dashboard hides the
      // Android screen-time bar for a child who carries both phones.
      expect(find.text('45 / 120 min'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(find.byKey(const ValueKey('iphoneScreenTime-child-1')), findsNothing);
    });

    testWidgets('mixed-device child (iPhone + Android) keeps Apps list and shows both platform headings', (tester) async {
      final api = FakeApiClient({
        ...standardRoutes(
          familyMe: familyJson(
            children: [childJson(id: 'child-1', displayName: 'Omar', screenTimeTodayMinutes: 45)],
            devices: [
              deviceJson(id: 'dev-ios', childId: 'child-1', platform: 'ios'),
              deviceJson(id: 'dev-and', childId: 'child-1', platform: 'android'),
            ],
          ),
        ),
        'GET /v1/rules/child-1': (_) => ruleSetPayload('child-1'),
        'GET /v1/devices/dev-and/apps': (_) => installedAppsPayload(
              apps: [installedAppJson('com.example.game', 'Game')],
            ),
      });

      await pumpRoute(tester, api, initialLocation: '/child/child-1');

      await tester.tap(find.text('Apps'));
      await tester.pumpAndSettle();

      // Mutant: treating a mixed-device child as `iphoneOnly` would suppress `appsTabAndroidHeading`
      // and `ChildAppsList`.
      expect(find.byKey(const ValueKey('appsTabIphoneHeading')), findsOneWidget);
      expect(find.text('iPhone apps'), findsOneWidget);
      expect(find.byKey(const ValueKey('appsTabAndroidHeading')), findsOneWidget);
      expect(find.text('Android apps'), findsOneWidget);
      expect(find.byType(IphoneAppDetailsCard), findsOneWidget);
      expect(find.byType(ChildAppsList), findsOneWidget);
    });

    testWidgets('unpaired child (devices: []) does not trigger iPhone empty state on Dashboard', (tester) async {
      final api = FakeApiClient({
        ...standardRoutes(
          familyMe: familyJson(
            children: [childJson(id: 'child-1', displayName: 'Omar', screenTimeTodayMinutes: 0)],
            devices: const [],
          ),
        ),
        'GET /v1/rules/child-1': (_) => ruleSetPayload('child-1'),
      });

      await pumpRoute(tester, api, initialLocation: '/');

      // Mutant: guessing iPhone from an empty device list would show `iphoneScreenTime-child-1`
      // for a newly added child who has not paired any device yet.
      expect(find.byKey(const ValueKey('iphoneScreenTime-child-1')), findsNothing);
      expect(find.text('0 / 120 min'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
    });
  });
}
