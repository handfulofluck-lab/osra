import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:familyshield_parent/features/children/child_detail_screen.dart';
import 'package:familyshield_parent/features/children/command_history_screen.dart';
import 'package:familyshield_parent/providers/auth_provider.dart';

import 'fake_api_client.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  Future<void> pumpScreen(WidgetTester tester, Widget home, FakeApiClient api,
      {Size? surface}) async {
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
      child: MaterialApp(home: home),
    ));
    await tester.pumpAndSettle();
  }

  Future<void> flushFakeHttp(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  /// Route table with canned device histories, keyed by device id.
  FakeApiClient historyApi({
    Map<String, List<Map<String, dynamic>>> histories =
        const <String, List<Map<String, dynamic>>>{
      'dev-1': [],
      'dev-2': [],
    },
  }) =>
      FakeApiClient({
        ...standardRoutes(),
        for (final entry in histories.entries)
          'GET /v1/devices/${entry.key}/commands/history': (_) =>
              {'items': entry.value},
      });

  final now = DateTime.now();
  List<Map<String, dynamic>> allStates() => [
        commandJson('cmd-acked', 'lock', 'acked',
            now.subtract(const Duration(minutes: 5)),
            deliveredAt: now.subtract(const Duration(minutes: 4)),
            ackedAt: now.subtract(const Duration(minutes: 3))),
        commandJson('cmd-delivered', 'ring', 'delivered',
            now.subtract(const Duration(minutes: 2)),
            deliveredAt: now.subtract(const Duration(minutes: 1))),
        commandJson('cmd-pending', 'pause_internet', 'pending',
            now.subtract(const Duration(minutes: 1))),
        commandJson('cmd-failed', 'unlock', 'failed',
            now.subtract(const Duration(minutes: 6)),
            deliveredAt: now.subtract(const Duration(minutes: 6)),
            ackedAt: now.subtract(const Duration(minutes: 5))),
        commandJson('cmd-expired', 'locate_now', 'expired',
            now.subtract(const Duration(hours: 1))),
      ];

  group('CommandHistoryScreen', () {
    testWidgets('lists every command with its real queue state and timestamps',
        (tester) async {
      final api = historyApi(histories: {'dev-1': allStates(), 'dev-2': []});
      await pumpScreen(
          tester, const CommandHistoryScreen(childId: 'child-1'), api);

      expect(find.text('Pixel 7a'), findsOneWidget);
      expect(find.text('Lock'), findsOneWidget);
      expect(find.text('Ring'), findsOneWidget);
      expect(find.text('Pause internet'), findsOneWidget);
      expect(find.text('Unlock'), findsOneWidget);
      expect(find.text('Locate now'), findsOneWidget);

      expect(find.text('Confirmed by device'), findsOneWidget);
      expect(find.text('Delivered — awaiting device confirmation'),
          findsOneWidget);
      expect(find.text('Pending — waiting for the device'), findsOneWidget);
      expect(find.text('Failed on device'), findsOneWidget);
      expect(find.text('Expired before delivery'), findsOneWidget);
      expect(find.textContaining('Created '), findsNWidgets(5));
    });

    // Plan 3.6 acceptance: UI never says "sent" for an unacked command.
    testWidgets(
        'never says "sent" for a pending or delivered-but-unacked command',
        (tester) async {
      final api = historyApi(histories: {
        'dev-1': [
          commandJson('cmd-delivered', 'ring', 'delivered',
              now.subtract(const Duration(minutes: 2)),
              deliveredAt: now.subtract(const Duration(minutes: 1))),
          commandJson('cmd-pending', 'pause_internet', 'pending',
              now.subtract(const Duration(minutes: 1))),
        ],
        'dev-2': [],
      });
      await pumpScreen(
          tester, const CommandHistoryScreen(childId: 'child-1'), api);

      expect(find.text('Delivered — awaiting device confirmation'),
          findsOneWidget);
      expect(find.text('Pending — waiting for the device'), findsOneWidget);
      expect(find.text('Confirmed by device'), findsNothing);
      expect(find.textContaining(RegExp('sent', caseSensitive: false)),
          findsNothing);
    });

    testWidgets('an unacked command on the device card is not called sent',
        (tester) async {
      final api = historyApi(histories: {
        'dev-1': [
          commandJson('cmd-delivered', 'ring', 'delivered',
              now.subtract(const Duration(minutes: 2)),
              deliveredAt: now.subtract(const Duration(minutes: 1))),
        ],
        'dev-2': [],
      });
      await pumpScreen(
          tester, const ChildDetailScreen(childId: 'child-1'), api);

      expect(
          find.textContaining(
              'Latest: Ring · Delivered — awaiting device confirmation'),
          findsOneWidget);
      expect(find.textContaining(RegExp('sent', caseSensitive: false)),
          findsNothing);
    });

    testWidgets('empty history shows an honest empty state per device',
        (tester) async {
      final api = historyApi();
      await pumpScreen(
          tester, const CommandHistoryScreen(childId: 'child-1'), api);

      expect(find.text('No commands yet'), findsWidgets);
      expect(find.textContaining('Confirmed by device'), findsNothing);
    });

    testWidgets(
        'a failed history request explains the failure and Retry refetches',
        (tester) async {
      var calls = 0;
      final api = FakeApiClient({
        ...standardRoutes(),
        'GET /v1/devices/dev-1/commands/history': (_) {
          calls++;
          return calls == 1
              ? const FakeHttpError(500, {'error': 'history_unavailable'})
              : {
                  'items': [
                    commandJson('cmd-acked', 'lock', 'acked',
                        now.subtract(const Duration(minutes: 1)),
                        deliveredAt: now.subtract(const Duration(minutes: 1)),
                        ackedAt: now),
                  ],
                };
        },
        'GET /v1/devices/dev-2/commands/history': (_) => {'items': <dynamic>[]},
      });
      await pumpScreen(
          tester, const CommandHistoryScreen(childId: 'child-1'), api);

      expect(find.text('Could not load command history'), findsOneWidget);
      expect(calls, 1);

      await tester.tap(find.text('Retry'));
      await flushFakeHttp(tester);
      await tester.pumpAndSettle();

      expect(calls, 2);
      expect(find.text('Could not load command history'), findsNothing);
      expect(find.text('Confirmed by device'), findsOneWidget);
    });

    testWidgets('layout survives a long device model at 320x568',
        (tester) async {
      final api = FakeApiClient({
        ...standardRoutes(
          familyMe: familyMeTwoChildren(
              alexModel: 'Samsung Galaxy S24 Ultra Enterprise Edition 5G'),
        ),
        'GET /v1/devices/dev-1/commands/history': (_) => {'items': allStates()},
        'GET /v1/devices/dev-2/commands/history': (_) => {'items': <dynamic>[]},
      });
      await pumpScreen(
          tester, const CommandHistoryScreen(childId: 'child-1'), api,
          surface: const Size(320, 568));

      final exceptions = <Object>[];
      while (true) {
        final e = tester.takeException();
        if (e == null) break;
        exceptions.add(e);
      }
      expect(exceptions, isEmpty, reason: exceptions.join('\n'));
    });
  });

  group('Reachability from the child detail screen', () {
    testWidgets(
        'the device card Delivery status button opens the history screen',
        (tester) async {
      final api = historyApi(histories: {'dev-1': allStates(), 'dev-2': []});
      final router = GoRouter(
        initialLocation: '/child/child-1',
        routes: [
          GoRoute(
              path: '/child/:id',
              builder: (_, s) =>
                  ChildDetailScreen(childId: s.pathParameters['id']!)),
          GoRoute(
              path: '/child/:id/commands',
              builder: (_, s) =>
                  CommandHistoryScreen(childId: s.pathParameters['id']!)),
        ],
      );
      await tester.pumpWidget(ProviderScope(
        overrides: [apiClientProvider.overrideWithValue(api)],
        child: MaterialApp.router(routerConfig: router),
      ));
      await tester.pumpAndSettle();

      final overviewScrollable = find
          .byWidgetPredicate((w) => w is Scrollable && w.axis == Axis.vertical)
          .first;
      await tester.scrollUntilVisible(find.text('Delivery status'), 120,
          scrollable: overviewScrollable);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delivery status'));
      await tester.pumpAndSettle();

      expect(find.byType(CommandHistoryScreen), findsOneWidget);
      expect(find.text('Command delivery'), findsOneWidget);
    });
  });
}
