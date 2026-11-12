import 'package:familyshield_parent/features/onboarding/setup_monitoring_screen.dart';
import 'package:familyshield_parent/providers/auth_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:familyshield_parent/features/social/social_screen.dart' show kSocialApps;
import 'package:familyshield_parent/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_api_client.dart';

/// Play decision 14 A — the monitored-apps step in setup.
///
/// The three facts this suite exists for: **every supported app starts ticked** (the product default is
/// unchanged), **the list is the same one the rules screen edits** (no second source of truth), and **the
/// consent numbers are on screen** (90-day excerpts, 12-month alerts), because a parent cannot consent to
/// something the screen does not say.
void main() {
  Future<void> pump(WidgetTester tester, {String? childId = 'child-1', Locale locale = const Locale('en')}) async {
    // A tall surface so all eight tiles are built: a `ListView` builds lazily, and a 600 px viewport would
    // leave half of them uncreated — the row would then assert on widgets that were never offered.
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: SetupMonitoringScreen(childId: childId),
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
        ['whatsapp', 'instagram', 'tiktok', 'snapchat', 'x', 'discord', 'roblox', 'line']);
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

    final rules = api.requests.where((r) => r.path.contains('/v1/rules/')).toList();
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
    expect(find.text('أي التطبيقات تريد أن يراقبها أسرة؟'), findsOneWidget);
    expect(find.text('متابعة'), findsOneWidget);
  });

  testWidgets('with no child id the step still lets the parent through, rather than blocking setup',
      (tester) async {
    // Onboarding must not dead-end on a missing parameter: the step is a choice, not a gate.
    await pump(tester, childId: null);
    expect(find.byKey(const ValueKey('setupMonitoringContinue')), findsOneWidget);
  });
}
