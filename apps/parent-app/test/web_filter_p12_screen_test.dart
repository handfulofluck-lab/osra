import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:familyshield_parent/features/rules/rules_editor_screen.dart';
import 'package:familyshield_parent/features/rules/web_filter_p12_screen.dart';
import 'package:familyshield_parent/l10n/app_localizations.dart';
import 'package:familyshield_parent/providers/auth_provider.dart';
import 'package:familyshield_parent/theme/app_theme.dart';

import 'fake_api_client.dart';

Map<String, dynamic> _overview({
  String platform = 'android',
  Map<String, String> features = const {'web_filter': 'ready'},
  List<String> missing = const [],
}) =>
    {
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
          'setup': {
            'reportedAt': '2026-11-26T12:00:00.000Z',
            'stale': false,
            'features': features,
            'missing': missing,
          },
        },
      ],
      'openAlerts': <dynamic>[],
    };

Map<String, dynamic> _rules({
  List<String> blockedCategories = const ['pornography'],
  List<String> allowedDomains = const [],
  List<String> blockedDomains = const [],
  bool safeSearchEnforced = true,
  String youtubeRestrictedMode = 'strict',
}) =>
    {
      'id': 'rule-1',
      'childId': 'child-1',
      'screenTime': {
        'dailyLimitMinutes': 120,
        'weekendLimitMinutes': 180,
        'bedtimeStart': '21:30',
        'bedtimeEnd': '07:00',
        'schoolStart': '07:45',
        'schoolEnd': '14:30',
        'schoolDays': [1, 2, 3, 4, 5],
      },
      'webFilter': {
        'blockedCategories': blockedCategories,
        'allowedDomains': allowedDomains,
        'blockedDomains': blockedDomains,
        'safeSearchEnforced': safeSearchEnforced,
        'youtubeRestrictedMode': youtubeRestrictedMode,
      },
      'appRules': <dynamic>[],
      'routines': <dynamic>[],
      'alwaysAllowedApps': <String>[],
    };

/// The reports summary as the server sends it. `withHosts: false` is the
/// site-names-off (or no-`social`) shape: the key is **absent**, not empty.
Map<String, dynamic> _summary({bool withHosts = true}) => {
      'childId': 'child-1',
      'days': 7,
      'totalAppMinutes': 60,
      'topApps': <dynamic>[],
      'urlVisits': 0,
      'socialConcerns': 0,
      'calls': 0,
      'sms': 0,
      if (withHosts)
        'topBlockedDomains': [
          {'domain': 'example.com', 'count': 3},
        ],
    };

FakeApiClient _makeApi({
  Map<String, dynamic>? overview,
  Map<String, dynamic>? rules,
  Map<String, dynamic>? summary,
}) =>
    FakeApiClient({
      'GET /v1/family/me': (_) => overview ?? _overview(),
      'GET /v1/rules/child-1': (_) => rules ?? _rules(),
      'GET /v1/reports/summary': (_) => summary ?? _summary(),
      'PATCH /v1/rules/child-1': (_) => {'ok': true},
    });

Widget _harness({
  required FakeApiClient api,
  required Widget home,
  Locale locale = const Locale('en'),
  ThemeMode themeMode = ThemeMode.light,
  double textScale = 1.0,
  bool p12Enabled = true,
}) {
  return ProviderScope(
    key: UniqueKey(),
    overrides: [
      apiClientProvider.overrideWithValue(api),
      p12WebFilterEnabledProvider.overrideWithValue(p12Enabled),
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

Future<void> _pumpScreen(
  WidgetTester tester, {
  FakeApiClient? api,
  Locale locale = const Locale('en'),
  ThemeMode themeMode = ThemeMode.light,
  double textScale = 1.0,
}) async {
  await tester.pumpWidget(_harness(
    api: api ?? _makeApi(),
    locale: locale,
    themeMode: themeMode,
    textScale: textScale,
    // Every row runs through the real host: the rules editor owns the draft and
    // the only Save, so a P-12 row that passed alone could hide a broken wire.
    home: const RulesEditorScreen(childId: 'child-1', initialTab: RulesEditorScreen.webFilterTab),
  ));
  await tester.pumpAndSettle();
}

Future<void> _save(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('rules-save-button')));
  await tester.pumpAndSettle();
}

/// The list scrolls: a card below the fold is not built yet, so a finder for it
/// is empty rather than "not there".
///
/// P-12 now lives in the editor's Web filter tab, so the screen owns two
/// scrollables (the tab strip and the list) and the default lookup is
/// ambiguous. Scroll the P-12 list itself when it is on screen.
Future<void> _scrollTo(WidgetTester tester, Finder finder) async {
  final p12List = find.byKey(const ValueKey('p12-list'));
  final scrollable = p12List.evaluate().isEmpty
      ? find.byType(Scrollable).first
      : find.descendant(of: p12List, matching: find.byType(Scrollable)).first;
  await tester.scrollUntilVisible(finder, 200, scrollable: scrollable);
  await tester.pumpAndSettle();
}

Map<String, dynamic> _lastWebFilterPatch(FakeApiClient api) {
  final patches =
      api.requests.where((r) => r.method == 'PATCH' && r.path == '/v1/rules/child-1').toList();
  expect(patches, hasLength(1));
  return Map<String, dynamic>.from(patches.single.body['webFilter'] as Map);
}

void main() {
  testWidgets(
      'OSRA_UX_P12 off keeps the legacy web-filter tab; on routes to P-12 '
      '(mutant: delete the _editorBody dispatch, and the off case renders P-12 while the on case keeps webFilterList)',
      (tester) async {
    final api = _makeApi();

    await tester.pumpWidget(_harness(
      api: api,
      p12Enabled: false,
      home: const RulesEditorScreen(
          childId: 'child-1', initialTab: RulesEditorScreen.webFilterTab),
    ));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('webFilterList')), findsOneWidget);
    expect(find.byType(WebFilterP12Screen), findsNothing);

    await tester.pumpWidget(_harness(
      api: api,
      p12Enabled: true,
      home: const RulesEditorScreen(
          childId: 'child-1', initialTab: RulesEditorScreen.webFilterTab),
    ));
    await tester.pumpAndSettle();
    expect(find.byType(WebFilterP12Screen), findsOneWidget);
    expect(find.byKey(const ValueKey('webFilterList')), findsNothing);
  });

  testWidgets(
      'category tiles read Blocked/Allowed in words and a tap takes the editor\'s draft '
      '(mutant: a tile that only paints its own state and never reaches the draft — the tile then stays "Allowed")',
      (tester) async {
    await _pumpScreen(tester);

    final gambling = find.byKey(const ValueKey('p12-category-gambling'));
    await _scrollTo(tester, gambling);
    final pornography = find.byKey(const ValueKey('p12-category-pornography'));
    expect(find.descendant(of: pornography, matching: find.text('Blocked')), findsOneWidget);
    expect(find.descendant(of: gambling, matching: find.text('Allowed')), findsOneWidget);

    await tester.tap(gambling);
    await tester.pumpAndSettle();
    expect(find.descendant(of: gambling, matching: find.text('Blocked')), findsOneWidget);
  });

  testWidgets(
      '"Allow site" on a recently blocked host opens filled with that exact domain, under the Bureau\'s own dialog title, and stores it verbatim '
      '(mutant: a field opened empty, or a stored value widened to www.<domain>)',
      (tester) async {
    final api = _makeApi();
    await _pumpScreen(tester, api: api);

    final allow = find.byKey(const ValueKey('p12-allow-example.com'));
    await _scrollTo(tester, allow);
    expect(
      find.descendant(of: allow, matching: find.text('Allow site')),
      findsOneWidget,
    );
    await tester.tap(allow);
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: find.byType(AlertDialog), matching: find.text('Allow a site')),
      findsOneWidget,
    );

    final field = tester.widget<TextField>(find.byKey(const ValueKey('p12-site-field')));
    expect(field.controller!.text, 'example.com');

    await tester.tap(find.byKey(const ValueKey('p12-site-save')));
    await tester.pumpAndSettle();

    await _scrollTo(tester, find.byKey(const ValueKey('p12-site-allow-example.com')));
    expect(find.byKey(const ValueKey('p12-site-allow-example.com')), findsOneWidget);
  });

  testWidgets(
      'Safe search and YouTube are one card carrying the UI/UX Bureau\'s binding line, and the mode saves '
      '(mutant: youtubeRestrictedDesc reverted to "Filters out potentially mature content…")',
      (tester) async {
    final api = _makeApi();
    await _pumpScreen(tester, api: api);

    final card = find.byKey(const ValueKey('p12-safe-search-youtube'));
    await _scrollTo(tester, card);
    expect(
      find.descendant(
        of: card,
        matching: find.text(
          "Hides most mature videos. YouTube's own filter misses some, so to be sure, block YouTube or set a time limit in Apps.",
        ),
      ),
      findsOneWidget,
    );
    expect(find.textContaining('Filters out potentially mature content'), findsNothing);
    expect(
      find.descendant(of: card, matching: find.byKey(const ValueKey('p12-safe-search-switch'))),
      findsOneWidget,
    );

    final off = find.text('Off');
    await tester.ensureVisible(off);
    await tester.pumpAndSettle();
    await tester.tap(off);
    await _save(tester);
    expect(_lastWebFilterPatch(api)['youtubeRestrictedMode'], 'off');
  });

  testWidgets(
      'a phone reporting the filter as degraded shows the enforcement banner and its pill '
      '(mutant: banner keyed on platform instead of the reported web_filter state)',
      (tester) async {
    await _pumpScreen(
      tester,
      api: _makeApi(
        overview: _overview(
          features: const {'web_filter': 'degraded'},
          missing: const ['web_filter'],
        ),
      ),
    );
    expect(find.byKey(const ValueKey('p12-enforcement-banner')), findsOneWidget);
    final pill = find.byKey(const ValueKey('p12-not-blocked-pill'));
    expect(pill, findsOneWidget);
    expect(find.descendant(of: pill, matching: find.text('Not blocking yet')), findsOneWidget);
    expect(find.textContaining('Web filter (VPN consent)'), findsOneWidget);
  });

  testWidgets(
      'a ready phone shows no enforcement banner and no pill '
      '(mutant: a banner shown for every child, so "ready" reads as broken)',
      (tester) async {
    await _pumpScreen(tester, api: _makeApi());
    expect(find.byKey(const ValueKey('p12-enforcement-banner')), findsNothing);
    expect(find.byKey(const ValueKey('p12-not-blocked-pill')), findsNothing);
  });

  testWidgets(
      '"Recently blocked" is hidden whole when the server withholds host names, and says "no blocked sites" for a real empty week '
      '(mutant: treating an absent key as an empty list — the network-off screen then claims a clean week)',
      (tester) async {
    await _pumpScreen(tester, api: _makeApi(summary: _summary(withHosts: false)));
    // Scroll past where the card would be, to a card that is always there, so the
    // absence is "hidden", not "not built yet".
    await _scrollTo(tester, find.byKey(const ValueKey('p12-blocked-sites-card')));
    expect(find.byKey(const ValueKey('p12-blocked-sites-card')), findsOneWidget);
    expect(find.byKey(const ValueKey('p12-blocked-card')), findsNothing);
    expect(find.byKey(const ValueKey('p12-recent-example.com')), findsNothing);
    expect(find.byKey(const ValueKey('p12-recently-empty')), findsNothing);
    expect(find.text('Recently blocked'), findsNothing);

    await _pumpScreen(
      tester,
      api: _makeApi(
        summary: _summary()
          ..['topBlockedDomains'] = <dynamic>[],
      ),
    );
    await _scrollTo(tester, find.byKey(const ValueKey('p12-recently-empty')));
    expect(find.byKey(const ValueKey('p12-blocked-card')), findsOneWidget);
    expect(find.text('Recently blocked'), findsOneWidget);
    expect(find.byKey(const ValueKey('p12-recent-example.com')), findsNothing);
  });

  testWidgets(
      'an iPhone-only child reads "Not yet available on iPhone" instead of the Android browser coverage line '
      '(mutant: branching on the Android wording for every platform)',
      (tester) async {
    await _pumpScreen(tester, api: _makeApi(overview: _overview(platform: 'ios')));
    await _scrollTo(tester, find.byKey(const ValueKey('p12-browsers-card')));
    final pill = find.byKey(const ValueKey('p12-iphone-not-available'));
    expect(pill, findsOneWidget);
    expect(
      find.descendant(of: pill, matching: find.text('Not yet available on iPhone')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('p12-browsers-android')), findsNothing);

    await _pumpScreen(tester, api: _makeApi());
    await _scrollTo(tester, find.byKey(const ValueKey('p12-browsers-card')));
    expect(find.byKey(const ValueKey('p12-browsers-android')), findsOneWidget);
    expect(find.byKey(const ValueKey('p12-iphone-not-available')), findsNothing);
  });

  testWidgets('Bureau matrix: zero overflow across EN/AR, light/dark, 390x844 @1x and 320x568 @2x',
      (tester) async {
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

      await _pumpScreen(
        tester,
        api: _makeApi(
          overview: _overview(features: const {'web_filter': 'degraded'}),
        ),
        locale: locale,
        themeMode: mode,
        textScale: scale,
      );
      expect(tester.takeException(), isNull,
          reason: 'Failed on $locale $mode $size @ ${scale}x');
    }
  });

  testWidgets(
      'Bureau compact rows: at 320x568 @2.0 the recently-blocked row and the iPhone pill stay inside the screen '
      '(mutant: put either Wrap back to a Row — measured: the recently-blocked Row overflows 41 px and the iPhone pill Row 476 px, at 320x568 @2.0 EN)',
      (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    for (final locale in const [Locale('en'), Locale('ar')]) {
      // The rows live below the fold and the list is lazy, so the top-only
      // matrix never laid them out; scroll to each one before asserting.
      await _pumpScreen(
        tester,
        api: _makeApi(overview: _overview(features: const {'web_filter': 'degraded'})),
        locale: locale,
        textScale: 2.0,
      );
      await _scrollTo(tester, find.byKey(const ValueKey('p12-recent-example.com')));
      expect(tester.takeException(), isNull, reason: 'recently-blocked row overflowed ($locale)');
      final allow = tester.getRect(find.byKey(const ValueKey('p12-allow-example.com')));
      expect(allow.right, lessThanOrEqualTo(320.0),
          reason: 'Allow site button past the right edge ($locale)');
      expect(allow.height, greaterThanOrEqualTo(47.9),
          reason: '48 dp touch target lost ($locale)');

      await _pumpScreen(
        tester,
        api: _makeApi(overview: _overview(platform: 'ios')),
        locale: locale,
        textScale: 2.0,
      );
      await _scrollTo(tester, find.byKey(const ValueKey('p12-browsers-card')));
      expect(tester.takeException(), isNull, reason: 'iPhone pill row overflowed ($locale)');
      final pill = tester.getRect(find.byKey(const ValueKey('p12-iphone-not-available')));
      expect(pill.right, lessThanOrEqualTo(320.0),
          reason: 'iPhone "Not yet available" pill past the right edge ($locale)');
    }
  });

  testWidgets(
      'Bureau compact layout: at 320x568 @2.0 the strength options become a vertical radio list, '
      'the status chip and the recommended header stop sharing their row, and the site dialog says "Add" '
      '(mutant: restore SegmentedButton / the shared banner row / SwitchListTile / l10n.save, and each label breaks mid-word again)',
      (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    Map<String, dynamic> degraded() =>
        _overview(features: const {'web_filter': 'degraded'});

    for (final locale in const [Locale('en'), Locale('ar')]) {
      final l10n = lookupAppLocalizations(locale);

      // Each check gets a fresh screen: the list is lazy and the test helper
      // scrolls one direction only, so starting at the top keeps it honest.

      // 1. Status chip has the row to itself: it sits below the warning icon.
      await _pumpScreen(tester, api: _makeApi(overview: degraded()),
          locale: locale, textScale: 2.0);
      final pill = find.byKey(const ValueKey('p12-not-blocked-pill'));
      expect(pill, findsOneWidget);
      final iconBottom = tester.getRect(find.byIcon(Icons.error_outline)).bottom;
      expect(tester.getRect(pill).top, greaterThanOrEqualTo(iconBottom),
          reason: 'status chip shares the title row ($locale)');

      // 2. Recommended header no longer squeezes its title behind a switch.
      await _pumpScreen(tester, api: _makeApi(overview: degraded()),
          locale: locale, textScale: 2.0);
      final recommended = find.byKey(const ValueKey('p12-recommended-card'));
      await _scrollTo(tester, recommended);
      expect(find.descendant(of: recommended, matching: find.byType(SwitchListTile)),
          findsNothing, reason: 'SwitchListTile squeezes the header ($locale)');
      expect(
          find.descendant(
              of: recommended, matching: find.byKey(const ValueKey('p12-recommended-switch'))),
          findsOneWidget);

      // 3. Strength options are a vertical radio list, not three segments.
      await _pumpScreen(tester, api: _makeApi(overview: degraded()),
          locale: locale, textScale: 2.0);
      await _scrollTo(tester, find.byKey(const ValueKey('p12-youtube-mode-strict')));
      expect(find.byType(SegmentedButton<String>), findsNothing,
          reason: 'horizontal segments split "Stri|ct" at 200% ($locale)');
      for (final mode in const ['strict', 'moderate', 'off']) {
        expect(find.byKey(ValueKey('p12-youtube-mode-$mode')), findsOneWidget);
      }

      // 4. The site dialog adds a site; it does not save the list.
      await _pumpScreen(tester, api: _makeApi(overview: degraded()),
          locale: locale, textScale: 2.0);
      await _scrollTo(tester, find.byKey(const ValueKey('p12-add-allowed')));
      await tester.tap(find.byKey(const ValueKey('p12-add-allowed')));
      await tester.pumpAndSettle();
      final saveButton = find.byKey(const ValueKey('p12-site-save'));
      expect(saveButton, findsOneWidget);
      expect(find.descendant(of: saveButton, matching: find.text(l10n.add)), findsOneWidget,
          reason: 'dialog button must read "Add", not "Save" ($locale)');
      expect(find.descendant(of: saveButton, matching: find.text(l10n.save)), findsNothing);
      await tester.tap(find.text(l10n.cancel));
      await tester.pumpAndSettle();

      // 5. At 1.0x the compact three-segment control is still the layout.
      await _pumpScreen(tester, api: _makeApi(overview: degraded()),
          locale: locale, textScale: 1.0);
      await _scrollTo(tester, find.byKey(const ValueKey('p12-youtube-mode')));
      expect(find.byType(SegmentedButton<String>), findsOneWidget,
          reason: 'normal text keeps the compact control ($locale)');
    }
  });

  testWidgets(
      'P-12 is reachable by the normal route: Child -> Rules (starts on Screen time) -> tap Web filter '
      '(mutant: gating on `initialTab` instead of the selected tab leaves the legacy list in place — this test then finds no p12-list)',
      (tester) async {
    final en = lookupAppLocalizations(const Locale('en'));
    for (final p12 in [true, false]) {
      await tester.pumpWidget(_harness(
        api: _makeApi(),
        p12Enabled: p12,
        // The normal route starts on Screen time; nothing here says "web filter".
        home: const RulesEditorScreen(childId: 'child-1'),
      ));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('p12-list')), findsNothing);
      await tester.tap(find.text(en.tabWebFilter));
      await tester.pumpAndSettle();

      if (p12) {
        expect(find.byKey(const ValueKey('p12-list')), findsOneWidget,
            reason: 'flag on must show P-12 after tapping the tab');
        expect(find.byKey(const ValueKey('webFilterList')), findsNothing);
      } else {
        expect(find.byKey(const ValueKey('webFilterList')), findsOneWidget,
            reason: 'flag off must keep the legacy list');
        expect(find.byKey(const ValueKey('p12-list')), findsNothing);
      }
    }
  });

  testWidgets(
      'the Searches and videos row pushes the real child id, not the literal \$childId '
      '(mutant: the escaped interpolation at :694 sends the literal dollar-childId and the destination sees it verbatim)',
      (tester) async {
    final router = GoRouter(routes: [
      GoRoute(
        path: '/',
        builder: (_, __) => const RulesEditorScreen(
            childId: 'child-1', initialTab: RulesEditorScreen.webFilterTab),
      ),
      GoRoute(
        path: '/child/:id/searches',
        builder: (_, s) => Scaffold(body: Text('searches:${s.pathParameters['id']}')),
      ),
    ]);
    addTearDown(router.dispose);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(_makeApi()),
        p12WebFilterEnabledProvider.overrideWithValue(true),
      ],
      child: MaterialApp.router(
        routerConfig: router,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
      ),
    ));
    await tester.pumpAndSettle();

    await _scrollTo(tester, find.byKey(const ValueKey('p12-searches-row')));
    await tester.tap(find.byKey(const ValueKey('p12-searches-row')));
    await tester.pumpAndSettle();

    expect(find.text('searches:child-1'), findsOneWidget);
    expect(find.text(r'searches:$childId'), findsNothing);
  });

  testWidgets(
      'the browser coverage sentence is only claimed when an Android phone reports the filter ready '
      '(mutant: rendering searchSafetyEmptyBody for a pending or degraded device claims enforcement nobody confirmed)',
      (tester) async {
    final cases = <String, Map<String, dynamic>>{
      'ready': _overview(),
      'degraded': _overview(features: const {'web_filter': 'degraded'}),
      'pending': _overview(features: const {}),
    };
    for (final entry in cases.entries) {
      await _pumpScreen(tester, api: _makeApi(overview: entry.value));
      await _scrollTo(tester, find.byKey(const ValueKey('p12-browsers-card')));
      final ready = entry.key == 'ready';
      expect(find.byKey(const ValueKey('p12-browsers-android')), ready ? findsOneWidget : findsNothing,
          reason: '${entry.key}: affirmative copy must follow the reported state');
      expect(find.byKey(const ValueKey('p12-browsers-not-ready')), ready ? findsNothing : findsOneWidget,
          reason: '${entry.key}: the fallback must be shown when the phone has not reported ready');
    }
  });
}
