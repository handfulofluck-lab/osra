import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:familyshield_parent/features/rules/rules_editor_screen.dart';
import 'package:familyshield_parent/features/rules/web_filter_p12_screen.dart';
import 'package:familyshield_parent/l10n/app_localizations.dart';
import 'package:familyshield_parent/providers/auth_provider.dart';
import 'package:familyshield_parent/theme/app_theme.dart';

import 'fake_api_client.dart';

/// #1238 review (Kimi-Mac, defect): P-12 replaced the editor's inner Save with
/// its own, but its edits never reached the editor's draft — so the editor's
/// footer Save submitted the old draft and the parent's change vanished.
///
/// These rows test the wire, not the screen: open the **rules editor** with the
/// P-12 switch on, edit there, press the editor's Save, and read the PATCH body.

Map<String, dynamic> _overview() => {
      'family': {'id': 'fam-1', 'name': 'Test Family'},
      'children': [
        {'id': 'child-1', 'displayName': 'Alex', 'birthYear': 2015},
      ],
      'devices': [
        {
          'id': 'dev-1',
          'childId': 'child-1',
          'platform': 'android',
          'model': 'Galaxy S23',
          'rulesVersion': 2,
          'appliedRulesVersion': 2,
          'setup': {
            'reportedAt': '2026-11-26T12:00:00.000Z',
            'stale': false,
            'features': {'web_filter': 'ready'},
            'missing': <String>[],
          },
        },
      ],
      'openAlerts': <dynamic>[],
    };

Map<String, dynamic> _rules() => {
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
        'blockedCategories': ['pornography'],
        'allowedDomains': <String>[],
        'blockedDomains': <String>[],
        'safeSearchEnforced': true,
        'youtubeRestrictedMode': 'strict',
      },
      'appRules': <dynamic>[],
      'routines': <dynamic>[],
      'alwaysAllowedApps': <String>[],
    };

FakeApiClient _makeApi() => FakeApiClient({
      'GET /v1/family/me': (_) => _overview(),
      'GET /v1/rules/child-1': (_) => _rules(),
      'GET /v1/reports/summary': (_) => {
            'childId': 'child-1',
            'days': 7,
            'totalAppMinutes': 60,
            'topApps': <dynamic>[],
            'urlVisits': 0,
            'topBlockedDomains': [
              {'domain': 'example.com', 'count': 3},
            ],
            'socialConcerns': 0,
            'calls': 0,
            'sms': 0,
          },
      'PATCH /v1/rules/child-1': (_) => {'ok': true},
    });

/// The rules editor with the P-12 switch on, on its web-filter tab.
Future<void> _pumpEditor(WidgetTester tester, FakeApiClient api) async {
  await tester.pumpWidget(ProviderScope(
    overrides: [
      apiClientProvider.overrideWithValue(api),
      p12WebFilterEnabledProvider.overrideWithValue(true),
    ],
    child: MaterialApp(
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: const RulesEditorScreen(childId: 'child-1', initialTab: RulesEditorScreen.webFilterTab),
    ),
  ));
  await tester.pumpAndSettle();
}

Future<void> _saveFromEditorFooter(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('rules-save-button')));
  await tester.pumpAndSettle();
}

Map<String, dynamic> _patchBody(FakeApiClient api) {
  final patches =
      api.requests.where((r) => r.method == 'PATCH' && r.path == '/v1/rules/child-1').toList();
  expect(patches, hasLength(1));
  return Map<String, dynamic>.from(patches.single.data as Map);
}

void main() {
  testWidgets(
      'integration: a category toggled on P-12 is in the editor footer Save '
      '(mutant: write to local state instead of the editor draft — the PATCH body then carries no webFilter at all)',
      (tester) async {
    final api = _makeApi();
    await _pumpEditor(tester, api);

    // The editor is hosting P-12 (not the legacy tab), and the only Save is the editor's.
    expect(find.byType(WebFilterP12Screen), findsOneWidget);
    expect(find.byKey(const ValueKey('p12-save-button')), findsNothing);

    final gambling = find.byKey(const ValueKey('p12-category-gambling'));
    await tester.scrollUntilVisible(gambling, 200);
    await tester.pumpAndSettle();
    await tester.tap(gambling);
    await tester.pumpAndSettle();

    await _saveFromEditorFooter(tester);
    final body = _patchBody(api);

    // Saved from the editor's own draft, through the editor's own changesFrom:
    // only the changed section, and no stale screen-time copy beside it.
    expect(body.keys, ['webFilter']);
    final webFilter = Map<String, dynamic>.from(body['webFilter'] as Map);
    expect(webFilter['blockedCategories'], ['pornography', 'gambling']);
  });

  testWidgets(
      'integration: an allow-site domain added on P-12 is in the editor footer Save '
      '(mutant: the dialog writes a screen-local copy, so the PATCH has no allowedDomains)',
      (tester) async {
    final api = _makeApi();
    await _pumpEditor(tester, api);

    final allow = find.byKey(const ValueKey('p12-allow-example.com'));
    await tester.scrollUntilVisible(allow, 200);
    await tester.pumpAndSettle();
    await tester.tap(allow);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('p12-site-save')));
    await tester.pumpAndSettle();

    await _saveFromEditorFooter(tester);
    final body = _patchBody(api);

    expect(body.keys, ['webFilter']);
    final webFilter = Map<String, dynamic>.from(body['webFilter'] as Map);
    expect(webFilter['allowedDomains'], ['example.com']);
  });
}
