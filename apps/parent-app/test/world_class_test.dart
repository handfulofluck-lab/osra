import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:familyshield_parent/api/models.dart' show LiveActivity, wellbeingColor;
import 'package:familyshield_parent/features/children/child_detail_screen.dart';
import 'package:familyshield_parent/features/dashboard/dashboard_screen.dart';
import 'package:familyshield_parent/features/reports/reports_screen.dart';
import 'package:familyshield_parent/features/settings/digest_prefs_screen.dart';
import 'package:familyshield_parent/providers/auth_provider.dart';
import 'package:familyshield_parent/providers/world_class_provider.dart';

import 'fake_api_client.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  Future<void> pumpScreen(WidgetTester tester, Widget home, FakeApiClient api) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [apiClientProvider.overrideWithValue(api)],
      child: MaterialApp(home: home),
    ));
    await tester.pumpAndSettle();
  }

  /// Lets a fake-Dio request chain complete (see widget_screens_test.dart).
  Future<void> flushFakeHttp(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Map<String, dynamic> cannedSummary() => {
        'totalAppMinutes': 300,
        'topApps': [
          {'name': 'YouTube', 'minutes': 120},
          {'name': 'TikTok', 'minutes': 90},
          {'name': 'Game', 'minutes': 60},
        ],
        'urlVisits': 42,
        'topBlockedDomains': [
          {'domain': 'tiktok.com', 'count': 12},
          {'domain': 'snapchat.com', 'count': 3},
        ],
        'socialConcerns': 2,
        'calls': 7,
        'sms': 15,
      };

  group('ReportsScreen (Feature #4)', () {
    FakeApiClient reportApi({Map<String, dynamic>? summary}) => FakeApiClient({
          ...standardRoutes(),
          'GET /v1/reports/summary': (_) => summary ?? cannedSummary(),
        });

    testWidgets('renders usage chart, web stats, YouTube note and social chips', (tester) async {
      final api = reportApi();
      await pumpScreen(tester, const ReportsScreen(childId: 'child-1'), api);

      // Usage section: bar chart present + totals text.
      expect(find.byKey(const ValueKey('usageBarChart')), findsOneWidget);
      expect(find.textContaining('Total 300 min'), findsOneWidget);
      expect(find.textContaining('avg 43 min/day'), findsOneWidget);
      expect(api.calls('GET', '/v1/reports/summary').single.query['days'], 7);

      // Web section: visits, blocked domains and the #7 YouTube NOTE.
      final scrollable = find.byType(Scrollable).first;
      await tester.scrollUntilVisible(find.text('tiktok.com'), 200, scrollable: scrollable);
      await tester.pumpAndSettle();
      expect(find.textContaining('42 URL visits'), findsOneWidget);
      expect(find.text('tiktok.com'), findsOneWidget);
      expect(find.textContaining('12× blocked'), findsOneWidget);
      expect(find.textContaining('YouTube search is forced to SafeSearch'), findsOneWidget);
      expect(find.textContaining('Restricted Mode needs HTTPS inspection'), findsOneWidget);

      // Social section chips.
      await tester.scrollUntilVisible(find.textContaining('social concerns'), 200, scrollable: scrollable);
      await tester.pumpAndSettle();
      expect(find.textContaining('2 social concerns'), findsOneWidget);
      expect(find.textContaining('7 calls'), findsOneWidget);
      expect(find.textContaining('15 SMS'), findsOneWidget);
    });

    testWidgets('switching to 30 days refetches with days=30', (tester) async {
      final api = reportApi();
      await pumpScreen(tester, const ReportsScreen(childId: 'child-1'), api);
      expect(api.calls('GET', '/v1/reports/summary'), hasLength(1));

      await tester.tap(find.text('30 days'));
      await flushFakeHttp(tester);
      await tester.pumpAndSettle();

      final calls = api.calls('GET', '/v1/reports/summary');
      expect(calls, hasLength(2));
      expect(calls.last.query['days'], 30);
    });

    testWidgets('empty summary shows the empty state', (tester) async {
      final api = reportApi(summary: const {});
      await pumpScreen(tester, const ReportsScreen(childId: 'child-1'), api);

      expect(find.text('No activity recorded in the last 7 days'), findsOneWidget);
      expect(find.byKey(const ValueKey('usageBarChart')), findsNothing);
    });
  });

  group('Wellbeing ring (Feature #28)', () {
    test('ring color thresholds: red < 50, amber < 75, green otherwise', () {
      expect(wellbeingColor(40), Colors.red);
      expect(wellbeingColor(60), Colors.amber);
      expect(wellbeingColor(85), Colors.green);
      expect(wellbeingColor(0), Colors.red);
      expect(wellbeingColor(50), Colors.amber);
      expect(wellbeingColor(75), Colors.green);
      expect(wellbeingColor(100), Colors.green);
    });

    testWidgets('dashboard cards render a ring per child with the threshold color', (tester) async {
      final api = FakeApiClient({
        ...standardRoutes(),
        'GET /v1/reports/wellbeing/child-1': (_) => {
              'childId': 'child-1',
              'week': '2026-W37',
              'score': 85,
              'breakdown': {'usage': 90, 'social': 80, 'safety': 85},
            },
        'GET /v1/reports/wellbeing/child-2': (_) => {
              'childId': 'child-2',
              'week': '2026-W37',
              'score': 40,
              'breakdown': {'usage': 45, 'social': 40, 'safety': 35},
            },
      });
      await pumpScreen(tester, const DashboardScreen(), api);

      expect(find.text('Wellbeing 85/100'), findsOneWidget);
      expect(find.text('Wellbeing 40/100'), findsOneWidget);
      final colors = tester
          .widgetList<CircularProgressIndicator>(find.byType(CircularProgressIndicator))
          .map((w) => w.color)
          .toList();
      expect(colors, containsAll([Colors.green, Colors.red]));
    });

    testWidgets('ring is hidden while the score fails to load', (tester) async {
      // standardRoutes has no wellbeing routes → fake 404 → no ring, no crash.
      final api = FakeApiClient(standardRoutes());
      await pumpScreen(tester, const DashboardScreen(), api);

      expect(find.textContaining('Wellbeing'), findsNothing);
      final exceptions = <Object>[];
      Object? e = tester.takeException();
      while (e != null) {
        exceptions.add(e);
        e = tester.takeException();
      }
      expect(exceptions, isEmpty);
    });
  });

  group('Live activity chip (Feature #29)', () {
    test('isFresh: entries newer than 2 minutes only', () {
      final now = DateTime(2026, 9, 16, 12, 0);
      expect(LiveActivity(childId: 'c', app: 'YouTube', minutesToday: 5, ts: now.subtract(const Duration(minutes: 1, seconds: 59))).isFresh(now), isTrue);
      expect(LiveActivity(childId: 'c', app: 'YouTube', minutesToday: 5, ts: now.subtract(const Duration(minutes: 2, seconds: 1))).isFresh(now), isFalse);
      expect(LiveActivity(childId: 'c', app: 'YouTube', minutesToday: 5).isFresh(now), isFalse);
    });

    testWidgets('chip appears when a live_activity update arrives and hides when stale', (tester) async {
      final api = FakeApiClient(standardRoutes());
      await pumpScreen(tester, const DashboardScreen(), api);
      expect(find.byKey(const ValueKey('liveChip-child-1')), findsNothing);

      // Inject the WS update the way wsProvider does on a live_activity event.
      final container = ProviderScope.containerOf(tester.element(find.byType(DashboardScreen)));
      container.read(liveActivityProvider.notifier).state = {
        'child-1': LiveActivity(childId: 'child-1', app: 'YouTube', minutesToday: 45, ts: DateTime.now()),
      };
      await tester.pump();
      expect(find.text('● YouTube · 45m today'), findsOneWidget);

      // A stale entry (> 2 min) must not render.
      container.read(liveActivityProvider.notifier).state = {
        'child-1': LiveActivity(childId: 'child-1', app: 'YouTube', minutesToday: 45, ts: DateTime.now().subtract(const Duration(minutes: 3))),
      };
      await tester.pump();
      expect(find.byKey(const ValueKey('liveChip-child-1')), findsNothing);
      expect(find.text('● YouTube · 45m today'), findsNothing);
    });
  });

  group('DigestPrefsScreen (Feature #5)', () {
    FakeApiClient digestApi() => FakeApiClient({
          ...standardRoutes(),
          'GET /v1/digests/prefs': (_) => {
                'dailyEmail': true,
                'weeklyEmail': false,
                'pushEnabled': true,
                'emails': ['qa@familyshield.dev'],
              },
          'PUT /v1/digests/prefs': (_) => {'ok': true},
          // ADR-0020 / #101: the screen loads the family zone and PATCHes a change.
          'GET /v1/family/me': (_) => {
                'family': {'id': 'fam-1', 'name': 'Demo', 'region': 'US', 'timezone': 'UTC', 'children': []},
              },
          'PATCH /v1/family/me': (req) => {
                'family': {'id': 'fam-1', 'timezone': req.body['timezone'], 'timezoneSource': 'parent'},
              },
          'POST /v1/digests/send-now': (_) => {
                'digests': [
                  {
                    'childId': 'child-1',
                    'displayName': 'Alex',
                    'markdown': '# Weekly digest\n- Screen time: 45 min\n- 2 concerns',
                  },
                ],
              },
        });

    testWidgets('timezone dropdown loads the family zone and PATCHes a change (ADR-0020)', (tester) async {
      final api = digestApi();
      await pumpScreen(tester, const DigestPrefsScreen(), api);
      await flushFakeHttp(tester);
      await tester.pumpAndSettle();

      // The zone is loaded from /v1/family/me and shown as the current value.
      expect(find.byKey(const ValueKey('digestTimezone')), findsOneWidget);
      expect(find.textContaining('sent at 18:00 your local time'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('digestTimezone')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Asia/Dubai').last);
      await flushFakeHttp(tester);
      await tester.pumpAndSettle();

      final patches = api.calls('PATCH', '/v1/family/me');
      expect(patches, hasLength(1));
      expect(patches.single.body['timezone'], 'Asia/Dubai');
      expect(find.textContaining('Digest timezone set to Asia/Dubai'), findsOneWidget);
    });

    testWidgets('a zone outside the curated list is shown, not replaced by UTC (#108)', (tester) async {
      final api = FakeApiClient({
        ...standardRoutes(),
        'GET /v1/digests/prefs': (_) => {
              'dailyEmail': true,
              'weeklyEmail': false,
              'pushEnabled': true,
              'emails': <String>[],
            },
        'GET /v1/family/me': (_) => {
              'family': {'id': 'fam-1', 'name': 'Demo', 'region': 'US', 'timezone': 'Asia/Tokyo', 'children': []},
            },
      });
      await pumpScreen(tester, const DigestPrefsScreen(), api);
      await flushFakeHttp(tester);
      await tester.pumpAndSettle();

      final dropdown = tester.widget<DropdownButtonFormField<String>>(
        find.byKey(const ValueKey('digestTimezone')),
      );
      expect(dropdown.initialValue, 'Asia/Tokyo');
      expect(find.textContaining('sent at 18:00 your local time'), findsOneWidget);
      // The displayed value matches the server: no PATCH was needed to correct it.
      expect(api.calls('PATCH', '/v1/family/me'), isEmpty);
    });

    testWidgets('loads server prefs; saving PUTs the switches and emails', (tester) async {
      final api = digestApi();
      await pumpScreen(tester, const DigestPrefsScreen(), api);

      final daily = find.widgetWithText(SwitchListTile, 'Daily email digest');
      final weekly = find.widgetWithText(SwitchListTile, 'Weekly email digest');
      expect(tester.widget<SwitchListTile>(daily).value, isTrue);
      expect(tester.widget<SwitchListTile>(weekly).value, isFalse);

      await tester.tap(weekly);
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(weekly).value, isTrue);

      await tester.tap(find.text('Save preferences'));
      await flushFakeHttp(tester);
      await tester.pumpAndSettle();

      final puts = api.calls('PUT', '/v1/digests/prefs');
      expect(puts, hasLength(1));
      expect(puts.single.body['dailyEmail'], isTrue);
      expect(puts.single.body['weeklyEmail'], isTrue);
      expect(puts.single.body['pushEnabled'], isTrue);
      expect(puts.single.body['emails'], ['qa@familyshield.dev']);
      expect(find.text('Digest preferences saved'), findsOneWidget);
      // Run out the snackbar so no timer is left pending at test end.
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    });

    testWidgets('send-now POSTs and shows the returned markdown in a dialog', (tester) async {
      final api = digestApi();
      await pumpScreen(tester, const DigestPrefsScreen(), api);

      await tester.tap(find.text('Send test digest now'));
      await flushFakeHttp(tester);
      await tester.pumpAndSettle();

      expect(api.calls('POST', '/v1/digests/send-now'), hasLength(1));
      expect(find.byType(SelectableText), findsOneWidget);
      expect(find.textContaining('# Weekly digest'), findsOneWidget);
      expect(find.textContaining('Screen time: 45 min'), findsOneWidget);

      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(find.text('Test digest'), findsNothing);
    });
  });

  group('App insights (Feature #12)', () {
    FakeApiClient insightsApi({bool known = true}) => FakeApiClient({
          ...standardRoutes(),
          if (known)
            'GET /v1/insights/apps': (req) => req.query['packageId'] == 'com.example.game'
                ? {
                      'packageId': 'com.example.game',
                      'appName': 'Game',
                      'ageRating': '13+',
                      'risks': ['In-app purchases', 'Chat with strangers'],
                      'alternatives': ['Toca Boca Kitchen'],
                    }
                : const FakeHttpError(404),
        });

    Future<void> openAppsTab(WidgetTester tester, FakeApiClient api) async {
      await pumpScreen(tester, const ChildDetailScreen(childId: 'child-1'), api);
      await tester.tap(find.text('Apps'));
      await tester.pumpAndSettle();
    }

    testWidgets('tapping an app row shows risks, age rating and alternatives', (tester) async {
      final api = insightsApi();
      await openAppsTab(tester, api);

      await tester.tap(find.text('Game'));
      await tester.pumpAndSettle();

      expect(api.calls('GET', '/v1/insights/apps').single.query['packageId'], 'com.example.game');
      expect(find.text('Age rating: 13+'), findsOneWidget);
      expect(find.text('In-app purchases'), findsOneWidget);
      expect(find.text('Chat with strangers'), findsOneWidget);
      expect(find.text('Toca Boca Kitchen'), findsOneWidget);

      // Dismiss the sheet via the modal barrier.
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      expect(find.text('Age rating: 13+'), findsNothing);
    });

    testWidgets('unknown app shows the no-insights placeholder', (tester) async {
      // No insights route (or explicit 404) → the curated DB has no entry.
      final api = FakeApiClient(standardRoutes());
      await openAppsTab(tester, api);

      await tester.tap(find.text('Game'));
      await tester.pumpAndSettle();

      expect(find.text('No insights for this app yet'), findsOneWidget);
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
    });
  });
}
