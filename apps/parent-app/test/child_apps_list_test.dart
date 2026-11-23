import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:familyshield_parent/app.dart' show appRoutes;
import 'package:familyshield_parent/features/children/child_apps_list.dart';
import 'package:familyshield_parent/l10n/app_localizations.dart';
import 'package:familyshield_parent/l10n/l10n.dart';
import 'package:familyshield_parent/providers/auth_provider.dart';

import 'fake_api_client.dart';

/// Karim, 23 Nov: "blocking and unblocking apps is a stupid flow and lacks any app icons".
/// The Apps tab lists every app on the phone with its icon and name, one switch per app, Undo, search,
/// filters, and a sheet for time limits. Package ids are never shown.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const png1x1 =
      'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==';

  final family = {
    'family': {'id': 'fam-1', 'name': 'Family', 'utcOffsetMinutes': 240},
    'children': [
      {'id': 'child-1', 'displayName': 'Omar', 'birthYear': 2015},
    ],
    'devices': [
      {
        'id': 'dev-and',
        'childId': 'child-1',
        'platform': 'android',
        'model': 'Galaxy Z Flip4',
        'osVersion': '14',
        'status': 'online',
        'batteryPct': 90,
      },
    ],
    'summary': [],
  };

  final appsReport = {
    'deviceId': 'dev-and',
    'version': 1,
    'reportedAt': '2026-11-23T07:00:00.000Z',
    'count': 4,
    'apps': [
      {'packageId': 'com.instagram.android', 'label': 'Instagram', 'isSystem': false, 'essential': false, 'iconUrl': png1x1},
      {'packageId': 'com.roblox.client', 'label': 'Roblox', 'isSystem': false, 'essential': false, 'iconUrl': null},
      {'packageId': 'com.whatsapp', 'label': 'WhatsApp', 'isSystem': false, 'essential': false, 'iconUrl': png1x1},
      {'packageId': 'com.samsung.android.dialer', 'label': 'Phone', 'isSystem': true, 'essential': true},
    ],
  };

  late List<Map<String, dynamic>> savedAppRules;

  FakeApiClient api() {
    savedAppRules = [
      {'packageId': 'com.roblox.client', 'appName': 'Roblox', 'action': 'block'},
    ];
    return FakeApiClient({
      ...standardRoutes(familyMe: family),
      'GET /v1/devices/dev-and/apps': (_) => appsReport,
      'GET /v1/rules/child-1': (_) => {...ruleSetPayload('child-1'), 'appRules': savedAppRules},
      'PATCH /v1/rules/child-1': (req) {
        savedAppRules = [for (final r in (req.body['appRules'] as List)) Map<String, dynamic>.from(r as Map)];
        return {...ruleSetPayload('child-1'), 'appRules': savedAppRules};
      },
    });
  }

  Future<void> openAppsTab(WidgetTester tester, FakeApiClient client, {Locale locale = const Locale('en')}) async {
    tester.view.physicalSize = const Size(393, 1400);
    tester.view.devicePixelRatio = 1.0;
    final router = GoRouter(initialLocation: '/child/child-1', routes: appRoutes);
    addTearDown(() {
      router.dispose();
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(ProviderScope(
      overrides: [apiClientProvider.overrideWithValue(client)],
      child: MaterialApp.router(
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        routerConfig: router,
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text(locale.languageCode == 'ar' ? 'التطبيقات' : 'Apps'));
    await tester.pumpAndSettle();
  }

  testWidgets('every reported app is listed with its icon and name, never its package id', (tester) async {
    await openAppsTab(tester, api());

    expect(find.byKey(const ValueKey('childAppsList')), findsOneWidget);
    for (final name in ['Instagram', 'Roblox', 'WhatsApp', 'Phone']) {
      expect(find.text(name), findsWidgets);
    }
    expect(find.textContaining('com.'), findsNothing, reason: 'a parent reads names, not package ids');
    // Instagram and WhatsApp carry a real icon (decoded from the data URI); Roblox draws its letter.
    expect(
      find.descendant(of: find.byKey(const ValueKey('appRow-com.instagram.android')), matching: find.byType(Image)),
      findsOneWidget,
    );
    expect(
      find.descendant(of: find.byKey(const ValueKey('appRow-com.roblox.client')), matching: find.text('R')),
      findsOneWidget,
    );
    expect(find.text('Blocked'), findsWidgets);
    expect(tester.widget<Switch>(find.byKey(const ValueKey('appSwitch-com.roblox.client'))).value, isFalse);
    expect(tester.widget<Switch>(find.byKey(const ValueKey('appSwitch-com.instagram.android'))).value, isTrue);
  });

  testWidgets('one tap blocks an app, saves at once, and Undo puts it back', (tester) async {
    final client = api();
    await openAppsTab(tester, client);

    await tester.tap(find.byKey(const ValueKey('appSwitch-com.instagram.android')));
    await tester.pumpAndSettle();

    final patch = client.calls('PATCH', '/v1/rules/child-1').single;
    expect(
      (patch.data['appRules'] as List).map((r) => '${r['packageId']}:${r['action']}'),
      containsAll(['com.roblox.client:block', 'com.instagram.android:block']),
    );
    expect(find.text('Instagram blocked'), findsOneWidget);
    expect(tester.widget<Switch>(find.byKey(const ValueKey('appSwitch-com.instagram.android'))).value, isFalse);

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    final undo = client.calls('PATCH', '/v1/rules/child-1').last;
    expect((undo.data['appRules'] as List).map((r) => r['packageId']), ['com.roblox.client']);
    expect(tester.widget<Switch>(find.byKey(const ValueKey('appSwitch-com.instagram.android'))).value, isTrue);
  });

  testWidgets('unblocking is the same single tap', (tester) async {
    final client = api();
    await openAppsTab(tester, client);
    await tester.tap(find.byKey(const ValueKey('appSwitch-com.roblox.client')));
    await tester.pumpAndSettle();
    expect(client.calls('PATCH', '/v1/rules/child-1').single.data['appRules'], isEmpty);
    expect(find.text('Roblox allowed'), findsOneWidget);
  });

  testWidgets('an app the phone needs for calls is always allowed and has no switch', (tester) async {
    await openAppsTab(tester, api());
    expect(find.byKey(const ValueKey('appSwitch-com.samsung.android.dialer')), findsNothing);
    expect(
      find.descendant(of: find.byKey(const ValueKey('appRow-com.samsung.android.dialer')), matching: find.text('Always allowed')),
      findsOneWidget,
    );
  });

  testWidgets('search and the Blocked filter narrow the list', (tester) async {
    await openAppsTab(tester, api());

    await tester.enterText(find.byKey(const ValueKey('appsSearch')), 'wha');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('appRow-com.whatsapp')), findsOneWidget);
    expect(find.byKey(const ValueKey('appRow-com.instagram.android')), findsNothing);

    await tester.enterText(find.byKey(const ValueKey('appsSearch')), '');
    await tester.tap(find.byKey(const ValueKey('appsFilterBlocked')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('appRow-com.roblox.client')), findsOneWidget);
    expect(find.byKey(const ValueKey('appRow-com.whatsapp')), findsNothing);
    expect(find.text('Blocked (1)'), findsOneWidget);
  });

  testWidgets('tapping a row offers a daily time limit', (tester) async {
    final client = api();
    await openAppsTab(tester, client);

    await tester.tap(find.byKey(const ValueKey('appRow-com.whatsapp')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('appSheetLimit-60')));
    await tester.pumpAndSettle();

    final rules = client.calls('PATCH', '/v1/rules/child-1').single.data['appRules'] as List;
    expect(rules.firstWhere((r) => r['packageId'] == 'com.whatsapp'),
        {'packageId': 'com.whatsapp', 'appName': 'WhatsApp', 'action': 'time_limit', 'dailyLimitMinutes': 60});
    expect(
      find.descendant(of: find.byKey(const ValueKey('appRow-com.whatsapp')), matching: find.text('Limit 1 h a day')),
      findsOneWidget,
    );
  });

  testWidgets('the list reads in Arabic', (tester) async {
    await openAppsTab(tester, api(), locale: const Locale('ar'));
    expect(find.text('محظور'), findsWidgets);
    expect(find.text('مسموح'), findsWidgets);
    expect(find.text('المحظورة (1)'), findsOneWidget);
  });

  test('limits read as minutes below an hour and as hours above', () {
    final en = lookupAppLocalizations(const Locale('en'));
    expect([for (final m in kAppLimitChoices) formatAppLimit(en, m)], ['15 min', '30 min', '1 h', '2 h']);
    expect(formatAppLimit(lookupAppLocalizations(const Locale('ar')), 120), '2 س');
  });
}
