import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:familyshield_parent/api/models.dart';
import 'package:familyshield_parent/app.dart' show appRoutes;
import 'package:familyshield_parent/features/children/child_apps_list.dart';
import 'package:familyshield_parent/l10n/app_localizations.dart';
import 'package:familyshield_parent/l10n/l10n.dart';
import 'package:familyshield_parent/providers/auth_provider.dart';

import 'fake_api_client.dart';

/// P-09 (`#1179`, UI/UX Bureau breakdown): the Apps tab states **Allow / Time limit / Block in words on every
/// row**, never a bare switch, with Undo, count filters, search, and a minutes sheet behind Limit. The three
/// words stack under the app name at 320 px or 200 % text (Fix 11). The iPhone state says the app list is not
/// available there yet (Fix 8).
///
/// The rows below pin the behaviour that existed before P-09 and must survive it: one save at a time, Undo
/// restoring the exact previous rule, essential apps never taking a rule, and names never being package ids.
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

  final iphoneFamily = {
    ...family,
    'devices': [
      {
        'id': 'dev-ios',
        'childId': 'child-1',
        'platform': 'ios',
        'model': 'iPhone 13',
        'osVersion': '18',
        'status': 'online',
        'batteryPct': 70,
      },
    ],
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

  FakeApiClient api({Map<String, dynamic>? familyMe}) {
    savedAppRules = [
      {'packageId': 'com.roblox.client', 'appName': 'Roblox', 'action': 'block'},
    ];
    return FakeApiClient({
      ...standardRoutes(familyMe: familyMe ?? family),
      'GET /v1/devices/dev-and/apps': (_) => appsReport,
      'GET /v1/devices/dev-ios/apps': (_) => appsReport,
      'GET /v1/rules/child-1': (_) => {...ruleSetPayload('child-1'), 'appRules': savedAppRules},
      'PATCH /v1/rules/child-1': (req) {
        savedAppRules = [for (final r in (req.body['appRules'] as List)) Map<String, dynamic>.from(r as Map)];
        return {...ruleSetPayload('child-1'), 'appRules': savedAppRules};
      },
    });
  }

  Future<void> openAppsTab(WidgetTester tester, FakeApiClient client,
      {Locale locale = const Locale('en'), bool uxP09 = true}) async {
    tester.view.physicalSize = const Size(393, 1400);
    tester.view.devicePixelRatio = 1.0;
    final router = GoRouter(initialLocation: '/child/child-1', routes: appRoutes);
    addTearDown(() {
      router.dispose();
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(client),
        // P-09 (#1179) ships behind `OSRA_UX_P09`; these rows test the new shape.
        p09AppsEnabledProvider.overrideWithValue(uxP09),
      ],
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

  /// The chosen word renders filled, the other two plain, so the row states its own state in words.
  bool wordSelected(WidgetTester tester, String action, String packageId) =>
      tester.widget(find.byKey(ValueKey('appAction-$action-$packageId'))) is FilledButton;

  bool wordEnabled(WidgetTester tester, String action, String packageId) =>
      tester.widget<ButtonStyleButton>(find.byKey(ValueKey('appAction-$action-$packageId'))).onPressed != null;

  testWidgets('every reported app is listed with its icon and name, never its package id', (tester) async {
    await openAppsTab(tester, api());

    expect(find.byKey(const ValueKey('childAppsList')), findsOneWidget);
    for (final name in ['Instagram', 'Roblox', 'WhatsApp', 'Phone']) {
      expect(find.text(name), findsWidgets);
    }
    expect(find.textContaining('com.'), findsNothing, reason: 'a parent reads names, not package ids');
    expect(
      find.descendant(of: find.byKey(const ValueKey('appRow-com.instagram.android')), matching: find.byType(Image)),
      findsOneWidget,
    );
    expect(
      find.descendant(of: find.byKey(const ValueKey('appRow-com.roblox.client')), matching: find.text('R')),
      findsOneWidget,
    );
    // P-09: no switch anywhere on the list; the state is the chosen word.
    expect(find.byType(Switch), findsNothing, reason: 'P-09 removes the bare switch from every row');
    expect(wordSelected(tester, 'block', 'com.roblox.client'), isTrue);
    expect(wordSelected(tester, 'allow', 'com.instagram.android'), isTrue);
  });

  testWidgets('one tap on Block saves at once, and Undo puts it back', (tester) async {
    final client = api();
    await openAppsTab(tester, client);

    await tester.tap(find.byKey(const ValueKey('appAction-block-com.instagram.android')));
    await tester.pumpAndSettle();

    final patch = client.calls('PATCH', '/v1/rules/child-1').single;
    expect(
      (patch.data['appRules'] as List).map((r) => '${r['packageId']}:${r['action']}'),
      containsAll(['com.roblox.client:block', 'com.instagram.android:block']),
    );
    expect(find.text('Instagram blocked'), findsOneWidget);
    expect(wordSelected(tester, 'block', 'com.instagram.android'), isTrue);

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    final undo = client.calls('PATCH', '/v1/rules/child-1').last;
    expect((undo.data['appRules'] as List).map((r) => r['packageId']), ['com.roblox.client']);
    expect(wordSelected(tester, 'allow', 'com.instagram.android'), isTrue);
  });

  // Codex on #1008: Undo must put back an explicit "Always allowed" as itself, not as "no rule".
  testWidgets('Undo after blocking an Always-allowed app restores the explicit allowance', (tester) async {
    final client = api();
    savedAppRules = [
      {'packageId': 'com.roblox.client', 'appName': 'Roblox', 'action': 'block'},
      {'packageId': 'com.whatsapp', 'appName': 'WhatsApp', 'action': 'allow'},
    ];
    await openAppsTab(tester, client);

    await tester.tap(find.byKey(const ValueKey('appAction-block-com.whatsapp')));
    await tester.pumpAndSettle();
    expect(find.text('WhatsApp blocked'), findsOneWidget);

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    final undo = client.calls('PATCH', '/v1/rules/child-1').last;
    expect(
      (undo.data['appRules'] as List).map((r) => '${r['packageId']}:${r['action']}'),
      unorderedEquals(['com.roblox.client:block', 'com.whatsapp:allow']),
    );
    expect(wordSelected(tester, 'allow', 'com.whatsapp'), isTrue);
  });

  // Codex, osra-security#71: while one save is in flight, no other rule edit can start.
  testWidgets('while a save is pending, every word on every row is inert', (tester) async {
    final pending = Completer<Object?>();
    savedAppRules = [
      {'packageId': 'com.roblox.client', 'appName': 'Roblox', 'action': 'block'},
    ];
    final routes = <String, FakeRoute>{
      ...standardRoutes(familyMe: family),
      'GET /v1/devices/dev-and/apps': (_) => appsReport,
      'GET /v1/rules/child-1': (_) => {...ruleSetPayload('child-1'), 'appRules': savedAppRules},
      'PATCH /v1/rules/child-1': (req) => FakeDeferred(pending.future),
    };
    final slow = FakeApiClient(routes);
    await openAppsTab(tester, slow);

    await tester.tap(find.byKey(const ValueKey('appAction-block-com.instagram.android')));
    await tester.pump(const Duration(milliseconds: 50));
    expect(slow.calls('PATCH', '/v1/rules/child-1'), hasLength(1));

    expect(wordEnabled(tester, 'allow', 'com.whatsapp'), isFalse);
    expect(wordEnabled(tester, 'time_limit', 'com.whatsapp'), isFalse);
    expect(wordEnabled(tester, 'block', 'com.whatsapp'), isFalse);
    await tester.tap(find.byKey(const ValueKey('appAction-block-com.whatsapp')), warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 50));
    expect(slow.calls('PATCH', '/v1/rules/child-1'), hasLength(1));

    pending.complete({...ruleSetPayload('child-1'), 'appRules': savedAppRules});
    await tester.pumpAndSettle();
    expect(wordEnabled(tester, 'allow', 'com.whatsapp'), isTrue);
  });

  testWidgets('saving an app says it was sent to the phone on that row', (tester) async {
    // The child has not reported the new rules version yet, so the line is earned and must show.
    var rulesVersion = 4;
    final behindFamily = {
      ...family,
      'children': [
        {'id': 'child-1', 'displayName': 'Omar', 'birthYear': 2015, 'rulesVersion': rulesVersion, 'appliedRulesVersion': 3},
      ],
    };
    savedAppRules = [
      {'packageId': 'com.roblox.client', 'appName': 'Roblox', 'action': 'block'},
    ];
    final client = FakeApiClient({
      ...standardRoutes(familyMe: behindFamily),
      'GET /v1/family/me': (_) => {
            ...behindFamily,
            'children': [
              {'id': 'child-1', 'displayName': 'Omar', 'birthYear': 2015, 'rulesVersion': rulesVersion, 'appliedRulesVersion': 3},
            ],
          },
      'GET /v1/devices/dev-and/apps': (_) => appsReport,
      'GET /v1/rules/child-1': (_) => {...ruleSetPayload('child-1'), 'appRules': savedAppRules},
      'PATCH /v1/rules/child-1': (req) {
        savedAppRules = [for (final r in (req.body['appRules'] as List)) Map<String, dynamic>.from(r as Map)];
        rulesVersion++;
        return {...ruleSetPayload('child-1'), 'appRules': savedAppRules};
      },
    });
    await openAppsTab(tester, client);
    expect(find.byKey(const ValueKey('appSentTo-com.whatsapp')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('appAction-block-com.whatsapp')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('appSentTo-com.whatsapp')), findsOneWidget,
        reason: 'P-09: the row says the change left the parent app for the phone');
    expect(
      find.descendant(of: find.byKey(const ValueKey('appRow-com.roblox.client')), matching: find.text('Sent to phone')),
      findsNothing,
      reason: 'only the row that changed carries the line',
    );
  });

  testWidgets('unblocking is the same single tap', (tester) async {
    final client = api();
    await openAppsTab(tester, client);
    await tester.tap(find.byKey(const ValueKey('appAction-allow-com.roblox.client')));
    await tester.pumpAndSettle();
    expect(client.calls('PATCH', '/v1/rules/child-1').single.data['appRules'], isEmpty);
    expect(find.text('Roblox allowed'), findsOneWidget);
  });

  testWidgets('an app the phone needs for calls is always allowed and has no words', (tester) async {
    await openAppsTab(tester, api());
    for (final action in ['allow', 'time_limit', 'block']) {
      expect(find.byKey(ValueKey('appAction-$action-com.samsung.android.dialer')), findsNothing);
    }
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

  // P-09: the Limit word opens the minutes sheet directly, instead of hiding the limit inside a menu.
  testWidgets('the Limit word opens the minutes sheet and saves the chosen limit', (tester) async {
    final client = api();
    await openAppsTab(tester, client);

    await tester.tap(find.byKey(const ValueKey('appAction-time_limit-com.whatsapp')));
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
    expect(wordSelected(tester, 'time_limit', 'com.whatsapp'), isTrue);
  });

  // P-09 / Fix 8: an iPhone child gets the approved line instead of an app list the phone cannot report.
  testWidgets('an iPhone child sees "Not yet available on iPhone" instead of the list', (tester) async {
    await openAppsTab(tester, api(familyMe: iphoneFamily));
    expect(find.byKey(const ValueKey('appsTabIphoneNotYet')), findsOneWidget);
    expect(find.text('Not yet available on iPhone'), findsOneWidget);
    expect(find.byKey(const ValueKey('childAppsList')), findsNothing);
  });

  // P-09 / Fix 11: the three words take the full width under the name, and nothing overflows.
  testWidgets('at 320 px and 200% text the words stack under the app name', (tester) async {
    final client = api();
    final ruleSet = RuleSet.fromJson({...ruleSetPayload('child-1'), 'appRules': savedAppRules});
    final report = InstalledAppsReport.fromJson(appsReport);
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(client),
        p09AppsEnabledProvider.overrideWithValue(true),
      ],
      child: MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: MediaQuery(
            data: const MediaQueryData(size: Size(320, 900), textScaler: TextScaler.linear(2)),
            child: SingleChildScrollView(
              child: ChildAppsList(childId: 'child-1', ruleSet: ruleSet, report: report),
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    final name = tester.getRect(find.text('WhatsApp'));
    final control = tester.getRect(find.byKey(const ValueKey('appAction-allow-com.whatsapp')));
    expect(control.top, greaterThanOrEqualTo(name.bottom - 1),
        reason: 'Fix 11: the words sit under the name at 320 px / 200%, never beside it');
    expect(tester.takeException(), isNull, reason: 'no row overflows at 320 px and 200%');
  });

  testWidgets('with the switch off the list keeps its switch row', (tester) async {
    // Claude, 18:51 UAE: every new screen ships with an off switch, so a screen can be turned off during the
    // test without a revert. Off must be the list exactly as it shipped — the switch row and its choice sheet.
    await openAppsTab(tester, api(), uxP09: false);

    expect(
        tester.widget<Switch>(find.byKey(const ValueKey('appSwitch-com.instagram.android'))).value,
        isTrue);
    expect(find.byKey(const ValueKey('appAction-block-com.instagram.android')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('appRow-com.whatsapp')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('appSheetBlock')), findsOneWidget,
        reason: 'the shipped choice sheet comes back with the switch row');
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
    // Arabic Language Bureau (#1008): full plurals, never «س».
    final ar = lookupAppLocalizations(const Locale('ar'));
    expect([for (final m in kAppLimitChoices) formatAppLimit(ar, m)], ['15 دقيقة', '30 دقيقة', 'ساعة واحدة', 'ساعتان']);
    expect(ar.appStateLimit(formatAppLimit(ar, 60)), 'الحد اليومي: ساعة واحدة');
  });
}
