import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:familyshield_parent/features/children/child_detail_screen.dart';
import 'package:familyshield_parent/features/rules/rules_editor_screen.dart';
import 'package:familyshield_parent/l10n/l10n.dart';
import 'package:familyshield_parent/providers/auth_provider.dart';

import 'fake_api_client.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

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
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final router = GoRouter(
      initialLocation: '/child/child-1',
      routes: [
        GoRoute(
          path: '/child/:id',
          builder: (_, s) => ChildDetailScreen(childId: s.pathParameters['id']!),
        ),
        GoRoute(
          path: '/child/:id/rules',
          builder: (_, s) => RulesEditorScreen(
            childId: s.pathParameters['id']!,
            initialTab: switch (s.uri.queryParameters['tab']) {
              'apps' => 2,
              _ => 0,
            },
          ),
        ),
      ],
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [apiClientProvider.overrideWithValue(api)],
        child: MaterialApp.router(
          locale: locale,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          routerConfig: router,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
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

  group('#937 ChildDetailScreen Apps tab block routes', () {
    testWidgets('iPhone-only with reported groups exposes group Block switch directly in Apps tab', (tester) async {
      final rules = ruleSetPayload('child-1');
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

      await tester.tap(find.byKey(const ValueKey('appGroup-$gamesId')));
      await tester.pumpAndSettle();

      final patch = api.calls('PATCH', '/v1/rules/child-1').single;
      expect(patch.body['appGroupRules'], [
        {'groupId': gamesId, 'action': 'block'},
      ]);
    });

    testWidgets('iPhone-only without reported groups shows group setup guidance instead of a dead end', (tester) async {
      final api = FakeApiClient({
        ...standardRoutes(familyMe: familyWithDevices([iphoneDevice()])),
        'GET /v1/rules/child-1': (_) => ruleSetPayload('child-1'),
      });

      await pumpAppsTab(tester, api);

      expect(find.byKey(const ValueKey('appsTabIphoneSetupCard')), findsOneWidget);
      expect(find.text('App groups on this iPhone'), findsOneWidget);
      expect(
        find.text("Groups are made on the child's iPhone, behind the parent PIN. Block one here and the iPhone shields its apps."),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('appsTabManageAppsButton')), findsNothing);
    });

    testWidgets('mixed iPhone + Android child exposes both group block controls and Apps-tab rules route', (tester) async {
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
      expect(find.byKey(const ValueKey('pickInstalledApp')), findsOneWidget);
    });

    testWidgets('Android-only empty state offers direct navigation to Rules Apps tab', (tester) async {
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
