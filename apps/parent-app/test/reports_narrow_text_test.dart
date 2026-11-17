import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:familyshield_parent/api/models.dart';
import 'package:familyshield_parent/core/ltr_isolate.dart';
import 'package:familyshield_parent/features/reports/reports_screen.dart';
import 'package:familyshield_parent/providers/auth_provider.dart';

import 'fake_api_client.dart';
import 'test_app.dart';

/// #841 conditions 4 and 5 (UI/UX Bureau): the reports screen at 320 px with 200 % text.
///
/// Condition 4 — "fewer ticks (at most 3), axis space that scales with text size, and app labels that wrap
/// below the bar instead of overlapping".
/// Condition 5 — "at narrow or large-text sizes, put the count on its own line under the host, not as a
/// trailing column".
///
/// Each row below is paired with the mutant it catches, stated in the row.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  const apps = [
    {'name': 'Google Play Services', 'minutes': 120},
    {'name': 'WhatsApp Business', 'minutes': 90},
    {'name': 'YouTube', 'minutes': 60},
  ];

  Map<String, dynamic> summaryJson() => {
        'totalAppMinutes': 270,
        'topApps': apps,
        'urlVisits': 42,
        'topBlockedDomains': [
          {'domain': 'tiktok.com', 'count': 12},
          {'domain': 'a-very-long-blocked-site.example.co.uk', 'count': 3},
        ],
        'socialConcerns': 1,
        'calls': 2,
        'sms': 3,
      };

  FakeApiClient reportApi() => FakeApiClient({
        ...standardRoutes(),
        'GET /v1/reports/summary': (_) => summaryJson(),
      });

  /// Pumps the reports screen at [width] logical pixels and [scale] text scale.
  Future<FakeApiClient> pumpReports(WidgetTester tester, {required double width, required double scale}) async {
    tester.view.physicalSize = Size(width, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final api = reportApi();
    await tester.pumpWidget(ProviderScope(
      overrides: [apiClientProvider.overrideWithValue(api)],
      child: MediaQuery(
        data: MediaQueryData(size: Size(width, 900), textScaler: TextScaler.linear(scale)),
        child: localizedTestApp(const ReportsScreen(childId: 'child-1')),
      ),
    ));
    await tester.pumpAndSettle();
    return api;
  }

  group('reports chart at 320 px / 200 % (condition 4)', () {
    test('the value axis draws at most three labels, whatever the busiest bar is', () {
      // Mutant: replace the /2 interval with the library default (interval = 0) — the axis then labels
      // every grid line it has room for and this assert fails on a tall window.
      const topApps = [
        TopApp(name: 'a', minutes: 120),
      ];
      final maxY = TopAppsChart.maxYFor(topApps);
      final interval = TopAppsChart.tickIntervalFor(topApps);
      final labels = (maxY / interval).floor();
      expect(labels, lessThanOrEqualTo(3), reason: 'labels at 0, i, 2i … must not exceed three');
      expect(interval, greaterThan(0), reason: 'a zero interval is how fl_chart divides by zero');
    });

    testWidgets('the whole app name is drawn under its bar, wrapped, with no eight-character cut',
        (tester) async {
      await pumpReports(tester, width: 320, scale: 2.0);

      expect(find.byKey(const ValueKey('usageBarChart')), findsOneWidget);
      // Mutant: put `name.substring(0, 8)` back — this row then finds 'Google P…' and no full name.
      expect(find.text('Google Play Services'), findsOneWidget);
      expect(find.text('WhatsApp Business'), findsOneWidget);
      expect(find.textContaining('…'), findsNothing);

      // At most three tick labels inside the chart (the axis draws two at this interval).
      final tickLabels = find.descendant(
        of: find.byKey(const ValueKey('usageBarChart')),
        matching: find.textContaining(' min'),
      );
      expect(tickLabels.evaluate().length, lessThanOrEqualTo(3));
    });

    testWidgets('the axis reserves more room at 200 % than at 100 %', (tester) async {
      await pumpReports(tester, width: 320, scale: 1.0);
      final narrow = TopAppsChart.axisWidthFor(
        tester.element(find.byType(TopAppsChart)),
        const [
          TopApp(name: 'a', minutes: 120),
        ],
      );

      await pumpReports(tester, width: 320, scale: 2.0);
      final wide = TopAppsChart.axisWidthFor(
        tester.element(find.byType(TopAppsChart)),
        const [
          TopApp(name: 'a', minutes: 120),
        ],
      );

      // Mutant: put `reservedSize: 64` back — a constant, so this difference is 0.
      expect(wide, greaterThan(narrow * 1.5), reason: '«132 min» at 200 % is more than twice as wide');
    });

    testWidgets('nothing overflows or throws at the smallest size the app supports', (tester) async {
      await pumpReports(tester, width: 320, scale: 2.0);
      expect(tester.takeException(), isNull);
    });
  });

  group('blocked-domain count at 320 px / 200 % (condition 5)', () {
    testWidgets('the count moves to its own line under the host', (tester) async {
      await pumpReports(tester, width: 320, scale: 2.0);

      final tile = find.byKey(const ValueKey('blockedDomain-tiktok.com'));
      expect(tile, findsOneWidget);
      final widget = tester.widget<ListTile>(tile);
      // Mutant: go back to `trailing: Text(l10n.blockedTimes(...))` at every width — trailing is non-null
      // and the host and the count are back to competing for the same row.
      expect(widget.trailing, isNull, reason: 'no trailing column at 320 px / 200 %');
      expect(widget.subtitle, isNotNull, reason: 'the count sits under the host instead');
      expect(find.descendant(of: tile, matching: find.text('12× blocked')), findsOneWidget);
    });

    testWidgets('the host itself is isolated and breakable at its dots, in full', (tester) async {
      await pumpReports(tester, width: 320, scale: 2.0);

      // Same rule as the history rows (condition 2): a host is a name, so it is drawn whole.
      expect(find.text(ltrIsolateHost('a-very-long-blocked-site.example.co.uk')), findsOneWidget);
    });

    testWidgets('on a wide screen at 100 % the count stays a trailing column', (tester) async {
      await pumpReports(tester, width: 800, scale: 1.0);

      final widget = tester.widget<ListTile>(find.byKey(const ValueKey('blockedDomain-tiktok.com')));
      expect(widget.trailing, isNotNull, reason: 'the wide layout the Bureau already reviewed is unchanged');
      expect(widget.subtitle, isNull);
    });
  });
}
