import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:familyshield_parent/features/rules/rules_editor_screen.dart';
import 'package:familyshield_parent/l10n/app_localizations.dart';
import 'package:familyshield_parent/providers/auth_provider.dart';
import 'package:familyshield_parent/theme/app_theme.dart';

import 'fake_api_client.dart';

/// U87 and U95 from #650 (Karim, 12:38 UAE): small parent-app copy and layout
/// polish that ships for Saturday, kept in its own stacked PR so no signed PR
/// is reopened.
void main() {
  test('U87: the web-filter grant row no longer says "VPN consent" in English', () {
    final en = lookupAppLocalizations(const Locale('en'));
    expect(en.grantWebFilter, 'Web filter');
    expect(en.grantWebFilter.toLowerCase().contains('vpn'), isFalse);
  });

  // U87's Arabic is the Arabic Language Bureau's line: «تصفية المواقع» without
  // the parenthetical. This test is added after their comment lands, so the
  // assertion cannot invent copy.
  testWidgets(
      'U95: the rules editor tab strip is start-aligned, so the first tab does not shift when it overflows '
      '(mutant: dropping `tabAlignment: TabAlignment.start` leaves the scrollable TabBar on its default)',
      (tester) async {
    final api = FakeApiClient({
      'GET /v1/family/me': (_) => {
            'family': {'id': 'fam-1', 'name': 'Test Family'},
            'children': [
              {'id': 'child-1', 'displayName': 'Alex', 'birthYear': 2015},
            ],
            'devices': <dynamic>[],
            'openAlerts': <dynamic>[],
          },
      'GET /v1/rules/child-1': (_) => {
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
              'blockedCategories': <String>[],
              'allowedDomains': <String>[],
              'blockedDomains': <String>[],
              'safeSearchEnforced': true,
              'youtubeRestrictedMode': 'strict',
            },
            'appRules': <dynamic>[],
            'routines': <dynamic>[],
            'alwaysAllowedApps': <String>[],
          },
      'GET /v1/reports/summary': (_) => {'childId': 'child-1', 'days': 7},
    });

    await tester.pumpWidget(ProviderScope(
      overrides: [apiClientProvider.overrideWithValue(api)],
      child: MaterialApp(
        theme: AppTheme.light,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const RulesEditorScreen(childId: 'child-1'),
      ),
    ));
    await tester.pumpAndSettle();

    final tabBar = tester.widget<TabBar>(find.byType(TabBar));
    expect(tabBar.isScrollable, isTrue);
    expect(tabBar.tabAlignment, TabAlignment.start);
  });
}
