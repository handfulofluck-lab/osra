import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:familyshield_parent/app.dart' show appRoutes;
import 'package:familyshield_parent/features/rules/rules_editor_screen.dart';
import 'package:familyshield_parent/l10n/l10n.dart';
import 'package:familyshield_parent/providers/auth_provider.dart';

import 'fake_api_client.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const gamesId = '6F1C2B8E-3D4A-4E5F-9A0B-1C2D3E4F5A6B';

  Map<String, dynamic> familyWithDevices(List<Map<String, dynamic>> devices) => {
        'family': {'id': 'fam-1', 'name': 'Family', 'utcOffsetMinutes': 240},
        'children': [
          {'id': 'child-1', 'displayName': 'Omar', 'birthYear': 2015},
        ],
        'devices': devices,
        'summary': [],
      };

  Map<String, dynamic> iphoneDevice({List<Map<String, dynamic>>? groups}) => {
        'id': 'dev-ios',
        'childId': 'child-1',
        'platform': 'ios',
        'model': 'iPhone 15',
        'osVersion': '18',
        'status': 'online',
        'batteryPct': 85,
        'setup': {
          'reportedAt': '2026-11-19T10:00:00.000Z',
          'features': <String, String>{},
          'missing': <String>[],
          if (groups != null) 'groups': groups,
        },
      };

  Map<String, dynamic> androidDevice() => {
        'id': 'dev-and',
        'childId': 'child-1',
        'platform': 'android',
        'model': 'Pixel 8',
        'osVersion': '15',
        'status': 'online',
        'batteryPct': 90,
      };

  Future<void> pumpAppsTab(
    WidgetTester tester,
    FakeApiClient api, {
    Size size = const Size(393, 852),
    double textScale = 1.0,
    Locale locale = const Locale('en'),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    final router = GoRouter(
      initialLocation: '/child/child-1',
      routes: appRoutes,
    );
    addTearDown(() {
      router.dispose();
      tester.platformDispatcher.clearTextScaleFactorTestValue();
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [apiClientProvider.overrideWithValue(api)],
        child: MaterialApp.router(
          locale: locale,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          routerConfig: router,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final tabFinder = find.text(locale.languageCode == 'ar' ? 'التطبيقات' : 'Apps');
    await tester.ensureVisible(tabFinder);
    await tester.pumpAndSettle();
    await tester.tap(tabFinder);
    await tester.pumpAndSettle();
  }

  group('#937 ChildDetailScreen Apps tab block routes (shipped appRoutes)', () {
    testWidgets('iPhone-only with reported groups exposes group Block switch directly in Apps tab', (tester) async {
      final rules = {...ruleSetPayload('child-1'), 'appRules': <Map<String, dynamic>>[]};
      final api = FakeApiClient({
        ...standardRoutes(
          familyMe: familyWithDevices([
            iphoneDevice(groups: [
              {'id': gamesId, 'label': 'Games', 'apps': 4, 'categories': 1, 'sites': 0},
            ]),
          ]),
        ),
        'GET /v1/rules/child-1': (_) => rules,
        'PATCH /v1/rules/child-1': (req) => {
              ...rules,
              'appGroupRules': req.body['appGroupRules'],
            },
      });

      await pumpAppsTab(tester, api);

      expect(find.byKey(const ValueKey('appGroupsSection')), findsOneWidget);
      expect(find.text('App groups on this iPhone'), findsOneWidget);
      expect(find.byKey(const ValueKey('appsTabManageAppsButton')), findsNothing);
      expect(find.text('No per-app rules'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('appGroup-$gamesId')));
      await tester.pumpAndSettle();

      final patch = api.calls('PATCH', '/v1/rules/child-1').single;
      expect(patch.body['appGroupRules'], [
        {'groupId': gamesId, 'action': 'block'},
      ]);
    });

    testWidgets('iPhone-only without reported groups shows group setup guidance instead of a dead end', (tester) async {
      final emptyRules = {...ruleSetPayload('child-1'), 'appRules': <Map<String, dynamic>>[]};
      final api = FakeApiClient({
        ...standardRoutes(familyMe: familyWithDevices([iphoneDevice()])),
        'GET /v1/rules/child-1': (_) => emptyRules,
      });

      await pumpAppsTab(tester, api);

      expect(find.byKey(const ValueKey('appsTabIphoneSetupCard')), findsOneWidget);
      expect(find.text('App groups on this iPhone'), findsOneWidget);
      expect(
        find.text("Groups are made on the child's iPhone, behind the parent PIN. Block one here and the iPhone shields its apps."),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('appsTabManageAppsButton')), findsNothing);
      expect(find.text('No per-app rules'), findsNothing);
    });

    testWidgets('mixed iPhone + Android child exposes both group block controls and shipped Rules Apps tab', (tester) async {
      final api = FakeApiClient({
        ...standardRoutes(
          familyMe: familyWithDevices([
            iphoneDevice(groups: [
              {'id': gamesId, 'label': 'Games', 'apps': 4, 'categories': 1, 'sites': 0},
            ]),
            androidDevice(),
          ]),
        ),
        'GET /v1/rules/child-1': (_) => ruleSetPayload('child-1'),
        'GET /v1/devices/child/child-1/apps': (_) => {
              'apps': [
                {'packageId': 'com.example.chat', 'label': 'Chat App'},
              ],
            },
      });

      await pumpAppsTab(tester, api);

      expect(find.byKey(const ValueKey('appGroupsSection')), findsOneWidget);
      expect(find.byKey(const ValueKey('appsTabManageAppsButton')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('appsTabManageAppsButton')));
      await tester.pumpAndSettle();

      expect(find.byType(RulesEditorScreen), findsOneWidget);
      // #931 and main both found that the Apps tab can be taller than a phone screen once the action
      // selector stacks, so the picker — the last row on the tab — is scrolled to rather than assumed to
      // be built inside the viewport. Main's finder is kept: it targets the vertical scrollable inside
      // the TabBarView, which is narrower than matching every down-axis Scrollable.
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('pickInstalledApp')),
        150,
        scrollable: find.descendant(
          of: find.byType(TabBarView),
          matching: find.byWidgetPredicate((w) => w is Scrollable && w.axis == Axis.vertical),
        ),
      );
      expect(find.byKey(const ValueKey('pickInstalledApp')), findsOneWidget);
    });

    testWidgets('Android-only empty state navigates via shipped router to Rules Apps tab', (tester) async {
      final emptyRules = {...ruleSetPayload('child-1'), 'appRules': <Map<String, dynamic>>[]};
      final api = FakeApiClient({
        ...standardRoutes(familyMe: familyWithDevices([androidDevice()])),
        'GET /v1/rules/child-1': (_) => emptyRules,
        'GET /v1/devices/child/child-1/apps': (_) => {'apps': []},
      });

      await pumpAppsTab(tester, api);

      expect(find.text('No per-app rules'), findsOneWidget);
      expect(find.byKey(const ValueKey('appsTabManageAppsButton')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('appsTabManageAppsButton')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('pickInstalledApp')), findsOneWidget);
    });

    for (final scale in [1.0, 2.0, 3.1]) {
      for (final locale in [const Locale('en'), const Locale('ar')]) {
        testWidgets(
          'renders cleanly without overflow at 320x568 scale=$scale locale=${locale.languageCode}',
          (tester) async {
            final api = FakeApiClient({
              ...standardRoutes(
                familyMe: familyWithDevices([
                  iphoneDevice(groups: [
                    {'id': gamesId, 'label': 'Games', 'apps': 4, 'categories': 1, 'sites': 0},
                  ]),
                  androidDevice(),
                ]),
              ),
              'GET /v1/rules/child-1': (_) => ruleSetPayload('child-1'),
            });

            await pumpAppsTab(
              tester,
              api,
              size: const Size(320, 568),
              textScale: scale,
              locale: locale,
            );
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
  });
}
