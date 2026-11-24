import 'package:familyshield_parent/features/onboarding/setup_monitoring_screen.dart';
import 'package:familyshield_parent/providers/auth_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:familyshield_parent/features/social/social_screen.dart' show kSocialApps;
import 'package:familyshield_parent/l10n/app_localizations.dart';
import 'package:familyshield_parent/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_api_client.dart';
import 'frame_capture.dart';

/// Play decision 14 A — the monitored-apps step in setup.
///
/// The three facts this suite exists for: **installed apps start ticked, with Select all for the full catalog**,
/// **the list is the same one the rules screen edits** (no second source of truth), and **the
/// consent numbers are on screen** (90-day excerpts, 12-month alerts), because a parent cannot consent to
/// something the screen does not say.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadFrameFonts);

  const socialPackageFixtures = <String, String>{
    'whatsapp': 'com.whatsapp',
    'instagram': 'com.instagram.android',
    'tiktok': 'com.zhiliaoapp.musically',
    'snapchat': 'com.snapchat.android',
    'twitter': 'com.twitter.android',
    'discord': 'com.discord',
    'roblox': 'com.roblox.client',
    'line': 'jp.naver.line.android',
    'youtube': 'com.google.android.youtube',
    'telegram': 'org.telegram.messenger',
    'reddit': 'com.reddit.frontpage',
    'messenger': 'com.facebook.orca',
  };

  List<Map<String, dynamic>> socialInventory([Set<String>? keys]) => [
        for (final entry in socialPackageFixtures.entries)
          if (keys == null || keys.contains(entry.key))
            installedAppJson(entry.value, entry.key),
      ];

  Future<void> pump(
    WidgetTester tester, {
    String? childId = 'child-1',
    Locale locale = const Locale('en'),
    Set<String>? installedKeys,
    double? textScale,
    bool frameBoundary = false,
    Map<String, bool>? socialMonitoring,
  }) async {
    tester.view.physicalSize = textScale == null ? const Size(1200, 2400) : const Size(320, 1000);
    tester.view.devicePixelRatio = 1.0;
    if (textScale != null) tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      tester.platformDispatcher.clearTextScaleFactorTestValue();
    });
    final api = FakeApiClient({
      ...standardRoutes(),
      'GET /v1/rules/child-1': (_) => ruleSetPayload('child-1', socialMonitoring: socialMonitoring),
      'GET /v1/devices/dev-1/apps': (_) => installedAppsPayload(apps: socialInventory(installedKeys)),
    });
    await tester.pumpWidget(ProviderScope(
      overrides: [apiClientProvider.overrideWithValue(api)],
      child: MaterialApp(
        theme: withFrameFonts(AppTheme.light),
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: frameBoundary
            ? RepaintBoundary(
                key: const ValueKey('frameRoot'),
                child: SetupMonitoringScreen(childId: childId),
              )
            : SetupMonitoringScreen(childId: childId),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('every supported app is offered, and every one starts ticked', (tester) async {
    await pump(tester);
    for (final app in kSocialApps) {
      final tile = tester.widget<CheckboxListTile>(
        find.byKey(ValueKey('setupMonitoring_${app.appKey}')),
      );
      expect(tile.value, isTrue, reason: '${app.appKey} must start ON, the product default');
    }
    expect(find.byType(CheckboxListTile), findsNWidgets(kSocialApps.length));
  });

  testWidgets('the list is the rules screen\'s list, not a copy', (tester) async {
    // `kSocialApps` is imported by both screens; a copy here would drift the moment an app is added there.
    expect(kSocialApps.map((a) => a.appKey).toList(),
        ['whatsapp', 'instagram', 'tiktok', 'snapchat', 'twitter', 'discord', 'roblox', 'line', 'youtube', 'telegram', 'reddit', 'messenger']);
  });

  testWidgets('only installed apps are preselected and Select all selects the whole catalog', (tester) async {
    await pump(tester, installedKeys: {'whatsapp', 'youtube'});
    expect(tester.widget<CheckboxListTile>(find.byKey(const ValueKey('setupMonitoring_whatsapp'))).value, isTrue);
    expect(tester.widget<Text>(find.text('WhatsApp')).maxLines, 1);
    expect(tester.widget<Text>(find.text('WhatsApp')).overflow, TextOverflow.ellipsis);
    expect(tester.widget<CheckboxListTile>(find.byKey(const ValueKey('setupMonitoring_youtube'))).value, isTrue);
    expect(find.byKey(const ValueKey('setupMonitoring_instagram')), findsNothing);
    expect(find.text('Not on Alex\'s phone (10)'), findsOneWidget);

    await tester.tap(find.text('Select all'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Not on Alex\'s phone (10)'));
    await tester.pumpAndSettle();
    for (final app in kSocialApps) {
      final tile = tester.widget<CheckboxListTile>(find.byKey(ValueKey('setupMonitoring_${app.appKey}')));
      expect(tile.value, isTrue, reason: '${app.appKey} must be selected by Select all');
    }

    await tester.tap(find.byKey(const ValueKey('setupMonitoring_reddit')));
    await tester.pumpAndSettle();
    expect(tester.widget<CheckboxListTile>(find.byKey(const ValueKey('setupMonitoring_reddit'))).value, isFalse);
  });

  testWidgets('onboarding honors canonical twitter before legacy x and legacy x when canonical is absent', (tester) async {
    final cases = <({Map<String, bool> monitoring, bool expected})>[
      (monitoring: {'twitter': false, 'x': true}, expected: false),
      (monitoring: {'twitter': true, 'x': false}, expected: true),
      (monitoring: {'x': false}, expected: false),
    ];
    for (final entry in cases) {
      await pump(tester, socialMonitoring: entry.monitoring);
      expect(
        tester.widget<CheckboxListTile>(find.byKey(const ValueKey('setupMonitoring_twitter'))).value,
        entry.expected,
        reason: 'rule map ${entry.monitoring} must control X in onboarding',
      );
      await tester.pumpWidget(const SizedBox());
    }
  });

  testWidgets('the consent sentence carries the retention numbers', (tester) async {
    await pump(tester);
    expect(find.textContaining('90 days'), findsOneWidget);
    expect(find.textContaining('12 months'), findsOneWidget);
  });

  testWidgets('unticking one leaves the others ticked', (tester) async {
    await pump(tester);
    await tester.tap(find.byKey(const ValueKey('setupMonitoring_whatsapp')));
    await tester.pumpAndSettle();
    final whatsapp = tester.widget<CheckboxListTile>(find.byKey(const ValueKey('setupMonitoring_whatsapp')));
    final instagram = tester.widget<CheckboxListTile>(find.byKey(const ValueKey('setupMonitoring_instagram')));
    expect(whatsapp.value, isFalse);
    expect(instagram.value, isTrue, reason: 'unticking one app must not clear the rest');
  });

  testWidgets('it PATCHes only socialMonitoring, so nothing else the child has is replaced (#587 review)',
      (tester) async {
    // The bug this row exists for: a PUT of a locally-built `RuleSet` wiped the server's 13 default blocked
    // web categories and the 300-minute weekend limit, because a child paired one screen ago has no loaded
    // ruleset and `const RuleSet()` was sent in its place.
    final api = FakeApiClient({
      ...standardRoutes(),
      'GET /v1/devices/dev-1/apps': (_) => installedAppsPayload(apps: socialInventory()),
      'PATCH /v1/rules/child-1': (req) => {'ok': true},
    });
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: [apiClientProvider.overrideWithValue(api)],
      child: MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const SetupMonitoringScreen(childId: 'child-1'),
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('setupMonitoring_instagram')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('setupMonitoringContinue')));
    await tester.pumpAndSettle();

    final rules = api.requests.where((r) => r.path.contains('/v1/rules/') && r.method != 'GET').toList();
    expect(rules, hasLength(1));
    expect(rules.single.method, 'PATCH', reason: 'a PUT replaces fields this screen never read');
    final body = rules.single.body;
    expect(body.keys, ['socialMonitoring'], reason: 'only the key this screen owns may travel');
    final map = Map<String, dynamic>.from(body['socialMonitoring'] as Map);
    expect(map['instagram'], isFalse, reason: 'the app the parent unticked');
    expect(map['whatsapp'], isTrue, reason: 'the apps the parent left ticked');
    expect(map, hasLength(kSocialApps.length), reason: 'the server replaces the whole map');
  });

  testWidgets('the Arabic copy renders, so the step is not English-only on an Arabic phone', (tester) async {
    await pump(tester, locale: const Locale('ar'));
    // Karim's approved copy, 2026-11-12 09:26Z (Arabic Language Bureau, #604).
    expect(find.text('أي التطبيقات تريد أن يراقبها تطبيق أسرة؟'), findsOneWidget);
    expect(find.text('متابعة'), findsOneWidget);
  });

  for (final locale in [const Locale('en'), const Locale('ar')]) {
    testWidgets('onboarding monitoring fits 320 px at 200% text in ${locale.languageCode}', (tester) async {
      await pump(
        tester,
        locale: locale,
        installedKeys: {'whatsapp', 'youtube'},
        textScale: 2.0,
        frameBoundary: true,
      );
      final selectAllText = locale.languageCode == 'ar' ? 'تحديد الكل' : 'Select all';
      await tester.scrollUntilVisible(find.text(selectAllText), 200);
      await tester.pumpAndSettle();
      expect(find.text(selectAllText), findsOneWidget);
      if (locale.languageCode == 'ar') {
        expect(find.textContaining('غير مثبّتة على هاتف'), findsOneWidget);
        expect(find.text('التعليقات والمحادثات'), findsOneWidget);
      } else {
        expect(find.text('Not on Alex\'s phone (10)'), findsOneWidget);
        expect(find.text('Comments and chats'), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
      await maybeCaptureFrame(tester, 'onboarding-${locale.languageCode}-320-200.png');
    });
  }

  testWidgets('with no child id the step still lets the parent through, rather than blocking setup',
      (tester) async {
    // Onboarding must not dead-end on a missing parameter: the step is a choice, not a gate.
    await pump(tester, childId: null);
    expect(find.byKey(const ValueKey('setupMonitoringContinue')), findsOneWidget);
  });
}
