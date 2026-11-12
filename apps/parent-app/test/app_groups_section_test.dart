import 'package:familyshield_parent/api/models.dart';
import 'package:familyshield_parent/features/children/app_groups_section.dart';
import 'package:familyshield_parent/providers/auth_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_api_client.dart';
import 'test_app.dart';

/// ADR-0037 PR B3c: the iPhone's app groups on the child screen, each with a Block switch writing
/// `appGroupRules`. Label and counts only; a switch changes its own group's rule and keeps every other.
void main() {
  const games = '6F1C2B8E-3D4A-4E5F-9A0B-1C2D3E4F5A6B';
  const video = '0E9D8C7B-6A5F-4E3D-8C2B-1A0F9E8D7C6B';

  Device iphone({List<Map<String, dynamic>>? groups}) => Device.fromJson({
        'id': 'dev-1',
        'childId': 'child-1',
        'platform': 'ios',
        'model': 'iPhone 13',
        'osVersion': '18',
        'status': 'online',
        'batteryPct': 80,
        'setup': {
          'reportedAt': '2026-11-12T05:00:00.000Z',
          'features': <String, String>{},
          'missing': <String>[],
          if (groups != null) 'groups': groups,
        },
      });

  final twoGroups = [
    {'id': games, 'label': 'Games', 'apps': 3, 'categories': 1, 'sites': 0},
    {'id': video, 'label': 'Video', 'apps': 2, 'categories': 0, 'sites': 4},
  ];

  Map<String, dynamic> rules(List<Map<String, String>> groupRules) => {
        'id': 'rs-1',
        'childId': 'child-1',
        'appRules': [],
        'appGroupRules': groupRules,
      };

  Future<FakeApiClient> pump(WidgetTester tester, Device d,
      {List<Map<String, String>> stored = const [], Locale locale = const Locale('en')}) async {
    final api = FakeApiClient({
      'GET /v1/rules/child-1': (_) => rules(stored),
      'PATCH /v1/rules/child-1': (r) => rules([for (final x in r.body['appGroupRules'] as List) Map<String, String>.from(x as Map)]),
    });
    await tester.pumpWidget(ProviderScope(
      overrides: [apiClientProvider.overrideWithValue(api)],
      child: localizedTestApp(Scaffold(body: SingleChildScrollView(child: AppGroupsSection(device: d))), locale: locale),
    ));
    await tester.pumpAndSettle();
    return api;
  }

  testWidgets('a phone with no groups shows nothing', (tester) async {
    await pump(tester, iphone());
    expect(find.byKey(const ValueKey('appGroupsSection')), findsNothing);
    await pump(tester, iphone(groups: const []));
    expect(find.byKey(const ValueKey('appGroupsSection')), findsNothing);
  });

  testWidgets('each group shows its label, its counts and whether the parent blocks it', (tester) async {
    await pump(tester, iphone(groups: twoGroups), stored: [
      {'groupId': games.toLowerCase(), 'action': 'block'},
    ]);
    expect(find.text('App groups on this iPhone'), findsOneWidget);
    expect(find.text('Games'), findsOneWidget);
    expect(find.text('Apps 3 · Categories 1 · Websites 0'), findsOneWidget);
    final gamesSwitch = tester.widget<SwitchListTile>(find.byKey(const ValueKey('appGroup-$games')));
    final videoSwitch = tester.widget<SwitchListTile>(find.byKey(const ValueKey('appGroup-$video')));
    expect(gamesSwitch.value, isTrue, reason: 'a lowercased stored id matches the phone\'s upper-case id');
    expect(videoSwitch.value, isFalse);
  });

  testWidgets('blocking a group adds its rule and keeps the others', (tester) async {
    final api = await pump(tester, iphone(groups: twoGroups), stored: [
      {'groupId': games, 'action': 'block'},
    ]);
    await tester.tap(find.byKey(const ValueKey('appGroup-$video')));
    await tester.pumpAndSettle();
    final patch = api.calls('PATCH', '/v1/rules/child-1').single;
    expect(patch.body.keys, ['appGroupRules'], reason: 'only the group rules are sent');
    expect(patch.body['appGroupRules'], [
      {'groupId': games, 'action': 'block'},
      {'groupId': video, 'action': 'block'},
    ]);
  });

  testWidgets('unblocking a group removes only its rule', (tester) async {
    final api = await pump(tester, iphone(groups: twoGroups), stored: [
      {'groupId': games, 'action': 'block'},
      {'groupId': video, 'action': 'block'},
    ]);
    await tester.tap(find.byKey(const ValueKey('appGroup-$games')));
    await tester.pumpAndSettle();
    expect(api.calls('PATCH', '/v1/rules/child-1').single.body['appGroupRules'], [
      {'groupId': video, 'action': 'block'},
    ]);
  });

  testWidgets('a failed save says so', (tester) async {
    final api = FakeApiClient({
      'GET /v1/rules/child-1': (_) => rules(const []),
      'PATCH /v1/rules/child-1': (_) => const FakeHttpError(500),
    });
    await tester.pumpWidget(ProviderScope(
      overrides: [apiClientProvider.overrideWithValue(api)],
      child: localizedTestApp(Scaffold(body: SingleChildScrollView(child: AppGroupsSection(device: iphone(groups: twoGroups))))),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('appGroup-$games')));
    await tester.pumpAndSettle();
    expect(find.text('Could not save the change. Try again.'), findsOneWidget);
  });

  testWidgets('Arabic renders the heading and the counts', (tester) async {
    await pump(tester, iphone(groups: twoGroups), locale: const Locale('ar'));
    expect(find.text('مجموعات التطبيقات على آيفون الطفل'), findsOneWidget);
    expect(find.text('التطبيقات: 3 · الفئات: 1 · المواقع: 0'), findsOneWidget);
  });

  test('appGroupRulesWith is case-insensitive and never duplicates', () {
    final current = [const AppGroupRule(groupId: games)];
    expect(appGroupRulesWith(current, games.toLowerCase(), true).map((r) => r.groupId), [games.toLowerCase()]);
    expect(appGroupRulesWith(current, games.toLowerCase(), false), isEmpty);
  });
}
