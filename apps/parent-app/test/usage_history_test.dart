import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:familyshield_parent/features/reports/reports_screen.dart';
import 'package:familyshield_parent/features/reports/usage_history_screen.dart';
import 'package:familyshield_parent/l10n/l10n.dart';
import 'package:familyshield_parent/providers/auth_provider.dart';

import 'fake_api_client.dart';
import 'test_app.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  Future<void> pumpScreen(WidgetTester tester, Widget home, FakeApiClient api, {Size? surface}) async {
    if (surface != null) {
      tester.view.physicalSize = surface;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
    }
    await tester.pumpWidget(ProviderScope(
      overrides: [apiClientProvider.overrideWithValue(api)],
      child: localizedTestApp(home),
    ));
    await tester.pumpAndSettle();
  }

  /// Fake-Dio chains complete on zero-duration timers; advance fake time.
  Future<void> flushFakeHttp(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  List<Object> drainExceptions(WidgetTester tester) {
    final exceptions = <Object>[];
    while (true) {
      final e = tester.takeException();
      if (e == null) return exceptions;
      exceptions.add(e);
    }
  }

  /// Fixed UTC days so the test does not depend on the wall clock.
  String isoDay(int offset) => DateTime.utc(2026, 9, 1).add(Duration(days: offset)).toIso8601String().substring(0, 10);

  /// `GET /v1/reports/usage` body. [values] is per-day minutes; days beyond its
  /// length are 0 (what the API's `usageSeries` produces for a gap).
  Map<String, dynamic> usagePayload(int days, {List<int>? values}) {
    final series = [
      for (var i = 0; i < days; i++)
        {
          'day': isoDay(i),
          'minutes': values != null && i < values.length ? values[i] : 0,
          'apps': const <Map<String, dynamic>>[],
        },
    ];
    return {
      'childId': 'child-1',
      'days': days,
      'totalMinutes': series.fold<int>(0, (n, m) => n + (m['minutes'] as int)),
      'series': series,
    };
  }

  Map<String, dynamic> visitJson(String id, String domain, bool blocked, DateTime ts) => {
        'id': id,
        'childId': 'child-1',
        'deviceId': 'dev-1',
        'domain': domain,
        'url': 'https://$domain/page',
        'blocked': blocked,
        'category': blocked ? 'social' : '',
        'ts': ts.toUtc().toIso8601String(),
      };

  /// Routes for the two 3.5 endpoints. [usageSeriesLength] shorter than the
  /// requested window simulates a server that returned fewer days than asked.
  FakeApiClient trendApi({
    int? usageSeriesLength,
    List<int>? usageMinutes,
    Object? usageError,
    List<Map<String, dynamic>>? visits,
    Object? webError,
  }) {
    final defaultVisits = [
      visitJson('v1', 'tiktok.com', true, DateTime.now().subtract(const Duration(minutes: 5))),
      visitJson('v2', 'khanacademy.org', false, DateTime.now().subtract(const Duration(minutes: 10))),
    ];
    return FakeApiClient({
      ...standardRoutes(),
      'GET /v1/reports/usage': (req) {
        if (usageError != null) return usageError;
        final length = usageSeriesLength ?? req.query['days'] as int;
        return usagePayload(length, values: usageMinutes);
      },
      'GET /v1/reports/web': (req) {
        if (webError != null) return webError;
        var items = visits ?? defaultVisits;
        if (req.query['blocked'] == 'true') {
          items = [for (final v in items) if (v['blocked'] == true) v];
        }
        final limit = req.query['limit'] as int;
        return {'childId': 'child-1', 'days': req.query['days'], 'items': items.take(limit).toList()};
      },
    });
  }

  group('UsageHistoryScreen — trend view (roadmap 3.5)', () {
    testWidgets('7/14/30-day selector refetches both endpoints with the chosen window', (tester) async {
      final api = trendApi(usageMinutes: List.filled(30, 12));
      await pumpScreen(tester, const UsageHistoryScreen(childId: 'child-1'), api);

      expect(api.calls('GET', '/v1/reports/usage').single.query['days'], 7);
      expect(api.calls('GET', '/v1/reports/web').single.query['days'], 7);

      await tester.tap(find.text('14d'));
      await flushFakeHttp(tester);
      await tester.pumpAndSettle();
      expect(api.calls('GET', '/v1/reports/usage').last.query['days'], 14);
      expect(api.calls('GET', '/v1/reports/web').last.query['days'], 14);

      await tester.tap(find.text('30d'));
      await flushFakeHttp(tester);
      await tester.pumpAndSettle();
      expect(api.calls('GET', '/v1/reports/usage').last.query['days'], 30);
      expect(api.calls('GET', '/v1/reports/web').last.query['days'], 30);
    });

    testWidgets('a 30-day series renders 30 bars, an honest total and a per-day list', (tester) async {
      final api = trendApi(usageMinutes: List.generate(30, (i) => i + 1));
      await pumpScreen(tester, const UsageHistoryScreen(childId: 'child-1'), api);

      await tester.tap(find.text('30d'));
      await flushFakeHttp(tester);
      await tester.pumpAndSettle();

      expect(find.byType(UsageBar), findsNWidgets(30));
      // 1 + 2 + ... + 30 = 465.
      expect(find.textContaining('Total 465 min over 30 days'), findsOneWidget);
      // The per-day list is readable without the chart.
      expect(find.byKey(const ValueKey('usageDay-2026-09-30')), findsOneWidget);
      expect(find.byKey(const ValueKey('usageDay-2026-09-01')), findsOneWidget);
      final lastRow = find.byKey(const ValueKey('usageDay-2026-09-30'));
      expect(find.descendant(of: lastRow, matching: find.text('30 min')), findsOneWidget);
    });

    testWidgets('a shorter series than requested is shown as-is and disclosed, never padded', (tester) async {
      final api = trendApi(usageSeriesLength: 3, usageMinutes: const [10, 20, 30]);
      await pumpScreen(tester, const UsageHistoryScreen(childId: 'child-1'), api);

      expect(find.byType(UsageBar), findsNWidgets(3));
      expect(find.textContaining('Total 60 min over 3 days'), findsOneWidget);
      expect(find.textContaining('Only 3 of the 7 requested days'), findsOneWidget);
      expect(find.byKey(const ValueKey('usageDay-2026-09-04')), findsNothing);
    });

    testWidgets('all-zero window shows the empty state and no chart', (tester) async {
      final api = trendApi(usageMinutes: List.filled(7, 0));
      await pumpScreen(tester, const UsageHistoryScreen(childId: 'child-1'), api);

      expect(find.text('No screen time recorded in the last 7 days'), findsOneWidget);
      expect(find.byType(UsageBar), findsNothing);
    });

    testWidgets('usage error shows an honest error and a retry, not a zero chart', (tester) async {
      final api = trendApi(usageError: const FakeHttpError(500));
      await pumpScreen(tester, const UsageHistoryScreen(childId: 'child-1'), api);

      expect(find.textContaining('Could not load screen time'), findsOneWidget);
      expect(find.byType(UsageBar), findsNothing);
      expect(find.text('No screen time recorded in the last 7 days'), findsNothing);
      expect(find.text('Try again'), findsOneWidget);
    });

    testWidgets('loading placeholders exist before data arrives', (tester) async {
      final api = trendApi(usageMinutes: List.filled(7, 15));
      await tester.pumpWidget(ProviderScope(
        overrides: [apiClientProvider.overrideWithValue(api)],
        child: localizedTestApp(const UsageHistoryScreen(childId: 'child-1')),
      ));

      expect(find.byKey(const ValueKey('usageLoading')), findsOneWidget);
      expect(find.byKey(const ValueKey('webLoading')), findsOneWidget);

      await flushFakeHttp(tester);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('usageLoading')), findsNothing);
      expect(find.byKey(const ValueKey('usageChart')), findsOneWidget);
    });
  });

  group('UsageHistoryScreen — browsing history (roadmap 3.5)', () {
    testWidgets('lists domain, time and blocked state', (tester) async {
      final api = trendApi();
      await pumpScreen(tester, const UsageHistoryScreen(childId: 'child-1'), api);

      expect(find.text('tiktok.com'), findsOneWidget);
      expect(find.text('khanacademy.org'), findsOneWidget);
      expect(find.text('Blocked'), findsOneWidget);
      expect(find.text('Allowed'), findsOneWidget);
    });

    testWidgets('Blocked only sends blocked=true and hides allowed visits', (tester) async {
      final api = trendApi();
      await pumpScreen(tester, const UsageHistoryScreen(childId: 'child-1'), api);

      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('blockedOnlyFilter')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.byKey(const ValueKey('blockedOnlyFilter')));
      await flushFakeHttp(tester);
      await tester.pumpAndSettle();

      expect(api.calls('GET', '/v1/reports/web').last.query['blocked'], 'true');
      expect(find.text('tiktok.com'), findsOneWidget);
      expect(find.text('khanacademy.org'), findsNothing);
    });

    testWidgets('Blocked only with no blocked visits shows the filtered empty state', (tester) async {
      final api = trendApi(visits: [
        visitJson('v2', 'khanacademy.org', false, DateTime.now()),
      ]);
      await pumpScreen(tester, const UsageHistoryScreen(childId: 'child-1'), api);

      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('blockedOnlyFilter')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.byKey(const ValueKey('blockedOnlyFilter')));
      await flushFakeHttp(tester);
      await tester.pumpAndSettle();

      expect(find.text('No blocked sites in the last 7 days'), findsOneWidget);
      expect(find.text('No browsing history in the last 7 days'), findsNothing);
    });

    testWidgets('limit control changes the requested limit and shows the truncation notice', (tester) async {
      final visits = [
        for (var i = 0; i < 25; i++)
          visitJson('v$i', 'site$i.example', false, DateTime.now().subtract(Duration(minutes: i))),
      ];
      final api = trendApi(visits: visits);
      await pumpScreen(tester, const UsageHistoryScreen(childId: 'child-1'), api);
      expect(api.calls('GET', '/v1/reports/web').single.query['limit'], 20);
      expect(find.textContaining('Showing the latest 20 visits'), findsOneWidget);
      expect(find.text('site19.example'), findsOneWidget);
      expect(find.text('site20.example'), findsNothing);

      final selector = find.byKey(const ValueKey('webLimitSelector'));
      await tester.scrollUntilVisible(selector, 200, scrollable: find.byType(Scrollable).first);
      await tester.tap(find.descendant(of: selector, matching: find.text('100')));
      await flushFakeHttp(tester);
      await tester.pumpAndSettle();

      expect(api.calls('GET', '/v1/reports/web').last.query['limit'], 100);
      expect(find.text('site24.example'), findsOneWidget);
      expect(find.textContaining('Showing the latest 100 visits'), findsNothing);
    });

    testWidgets('empty history shows the empty state', (tester) async {
      final api = trendApi(visits: const []);
      await pumpScreen(tester, const UsageHistoryScreen(childId: 'child-1'), api);

      expect(find.text('No browsing history in the last 7 days'), findsOneWidget);
    });

    testWidgets('web error shows an honest error and a retry', (tester) async {
      final api = trendApi(webError: const FakeHttpError(500));
      await pumpScreen(tester, const UsageHistoryScreen(childId: 'child-1'), api);

      expect(find.textContaining('Could not load browsing history'), findsOneWidget);
      expect(find.text('No browsing history in the last 7 days'), findsNothing);
      expect(find.text('Try again'), findsOneWidget);
    });
  });

  group('UsageHistoryScreen — entry point and layout', () {
    testWidgets('reports screen opens the history screen for the same child', (tester) async {
      final api = FakeApiClient(standardRoutes());
      final router = GoRouter(
        initialLocation: '/child/child-1/reports',
        routes: [
          GoRoute(path: '/child/:id/reports', builder: (_, s) => ReportsScreen(childId: s.pathParameters['id']!)),
          GoRoute(path: '/child/:id/history', builder: (_, s) => UsageHistoryScreen(childId: s.pathParameters['id']!)),
        ],
      );
      await tester.pumpWidget(ProviderScope(
        overrides: [apiClientProvider.overrideWithValue(api)],
        child: MaterialApp.router(
          routerConfig: router,
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
        ),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('usageHistoryButton')));
      await tester.pumpAndSettle();

      expect(find.byType(UsageHistoryScreen), findsOneWidget);
      expect(api.calls('GET', '/v1/reports/usage').single.query['childId'], 'child-1');
    });

    testWidgets('320x568: selector, 30 bars and the browsing controls do not overflow', (tester) async {
      final api = trendApi(
        usageMinutes: List.generate(30, (i) => i * 3),
        visits: [
          visitJson('v1', 'a-very-long-subdomain.example-with-a-long-name.com', true, DateTime.now()),
        ],
      );
      await pumpScreen(tester, const UsageHistoryScreen(childId: 'child-1'), api, surface: const Size(320, 568));

      await tester.tap(find.text('30d'));
      await flushFakeHttp(tester);
      await tester.pumpAndSettle();
      expect(find.byType(UsageBar), findsNWidgets(30));

      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('webLimitSelector')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();

      final exceptions = drainExceptions(tester);
      expect(exceptions, isEmpty, reason: exceptions.join('\n'));
    });
  });
}
