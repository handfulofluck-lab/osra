import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:familyshield_parent/api/models.dart';
import 'package:familyshield_parent/features/alerts/alerts_screen.dart';
import 'package:familyshield_parent/features/dashboard/dashboard_screen.dart';
import 'package:familyshield_parent/l10n/l10n.dart';
import 'package:familyshield_parent/providers/auth_provider.dart';
import 'package:familyshield_parent/providers/family_provider.dart';
import 'package:familyshield_parent/providers/onboarding_provider.dart';

import 'fake_api_client.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({kOnboardingCompleteKey: true});
  });

  final _effectsProvider = Provider<RealtimeEffects>((ref) => RealtimeEffects.fromRef(ref));

  Widget buildRouterApp({required GoRouter router}) {
    return MaterialApp.router(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      routerConfig: router,
    );
  }

  group('#936 notifications bell seen state', () {
    testWidgets(
      'clears badge after viewing feed, keeps explicit ack intact, and increments on later alert',
      (tester) async {
        final now = DateTime.now().toUtc();
        final serverAlerts = <Map<String, dynamic>>[
          {
            ...alertJson('a2', 'warning', 'web_threat', 'Blocked site visit', now),
            'acknowledged': false,
            'attemptCount': 1,
          },
          {
            ...alertJson('a1', 'critical', 'sos', 'SOS alert', now.subtract(const Duration(minutes: 5))),
            'acknowledged': false,
            'attemptCount': 1,
          },
        ];

        final api = FakeApiClient({
          ...standardRoutes(),
          'GET /v1/alerts': (req) {
            if (req.query['ack'] == 'false') {
              final unacked = serverAlerts.where((a) => a['acknowledged'] != true).toList();
              return {
                'items': unacked,
                'meta': {'total': unacked.length, 'page': 1, 'limit': 50},
              };
            }
            return {
              'items': List<Map<String, dynamic>>.from(serverAlerts),
              'meta': {'total': serverAlerts.length, 'page': 1, 'limit': 20},
            };
          },
          'POST /v1/alerts/a2/ack': (_) {
            for (final a in serverAlerts) {
              if (a['id'] == 'a2') a['acknowledged'] = true;
            }
            return {'ok': true};
          },
        });

        final router = GoRouter(
          initialLocation: '/',
          routes: [
            GoRoute(path: '/', builder: (_, __) => const DashboardScreen()),
            GoRoute(path: '/alerts', builder: (_, __) => const AlertsScreen()),
          ],
        );

        await tester.pumpWidget(
          ProviderScope(
            overrides: [apiClientProvider.overrideWithValue(api)],
            child: buildRouterApp(router: router),
          ),
        );
        await tester.pumpAndSettle();

        // 1. Dashboard starts with 2 unacked, unseen alerts on the bell badge.
        final badgeBefore = tester.widget<Badge>(find.byType(Badge));
        expect(badgeBefore.isLabelVisible, isTrue);
        expect(find.descendant(of: find.byType(Badge), matching: find.text('2')), findsOneWidget);

        // 2. Tap bell -> open feed, both existing alerts stay visible and unacknowledged.
        await tester.tap(find.byIcon(Icons.notifications_outlined));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('a2')), findsOneWidget);
        expect(find.byKey(const ValueKey('a1')), findsOneWidget);
        expect(api.calls('POST', '/v1/alerts/a2/ack'), isEmpty);

        // 3. Return to dashboard -> badge is cleared even though server ack count is still 2.
        await tester.tap(find.byTooltip('Back'));
        await tester.pumpAndSettle();
        final badgeAfterView = tester.widget<Badge>(find.byType(Badge));
        expect(badgeAfterView.isLabelVisible, isFalse);

        final container = ProviderScope.containerOf(tester.element(find.byType(DashboardScreen)));
        expect(await container.read(unacknowledgedCountProvider.future), 2);

        // 4. Open feed again and deliberately acknowledge one alert via swipe -> ack fires & badge stays clear.
        await tester.tap(find.byIcon(Icons.notifications_outlined));
        await tester.pumpAndSettle();
        await tester.drag(find.byKey(const ValueKey('a2')), const Offset(-600, 0));
        for (var i = 0; i < 10; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        await tester.pumpAndSettle();
        expect(api.calls('POST', '/v1/alerts/a2/ack'), hasLength(1));
        expect(find.byKey(const ValueKey('a1')), findsOneWidget);

        await tester.tap(find.byTooltip('Back'));
        await tester.pumpAndSettle();
        expect(tester.widget<Badge>(find.byType(Badge)).isLabelVisible, isFalse);

        // 5. A new alert arrives later -> bell badge increments from 0 to 1.
        serverAlerts.insert(0, {
          ...alertJson('a3', 'critical', 'tamper', 'Tamper alert', now.add(const Duration(minutes: 1))),
          'acknowledged': false,
          'attemptCount': 1,
        });
        applyRealtimeMessage(container.read(_effectsProvider), {
          'type': 'alert',
          'payload': {'id': 'a3', 'acknowledged': false, 'attemptCount': 1},
        });
        for (var i = 0; i < 10; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        await tester.pumpAndSettle();

        final badgeOnNewAlert = tester.widget<Badge>(find.byType(Badge));
        expect(badgeOnNewAlert.isLabelVisible, isTrue);
        expect(find.descendant(of: find.byType(Badge), matching: find.text('1')), findsOneWidget);
      },
    );

    testWidgets('failed feed load does not mark unseen alerts as seen', (tester) async {
      final now = DateTime.now().toUtc();
      var failFeed = true;
      final serverAlerts = <Map<String, dynamic>>[
        {
          ...alertJson('a1', 'critical', 'sos', 'SOS alert', now),
          'acknowledged': false,
          'attemptCount': 1,
        },
      ];

      final api = FakeApiClient({
        ...standardRoutes(),
        'GET /v1/alerts': (req) {
          if (req.query['ack'] == 'false') {
            return {
              'items': serverAlerts,
              'meta': {'total': serverAlerts.length, 'page': 1, 'limit': 50},
            };
          }
          if (failFeed) {
            return const FakeHttpError(500, {'error': 'db_timeout'});
          }
          return {
            'items': serverAlerts,
            'meta': {'total': serverAlerts.length, 'page': 1, 'limit': 20},
          };
        },
      });

      final router = GoRouter(
        initialLocation: '/',
        routes: [
          GoRoute(path: '/', builder: (_, __) => const DashboardScreen()),
          GoRoute(path: '/alerts', builder: (_, __) => const AlertsScreen()),
        ],
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [apiClientProvider.overrideWithValue(api)],
          child: buildRouterApp(router: router),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.widget<Badge>(find.byType(Badge)).isLabelVisible, isTrue);

      // Opening the feed fails with 500 -> returning to dashboard keeps badge visible.
      await tester.tap(find.byIcon(Icons.notifications_outlined));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();

      final badgeAfterFailure = tester.widget<Badge>(find.byType(Badge));
      expect(badgeAfterFailure.isLabelVisible, isTrue);
      expect(find.descendant(of: find.byType(Badge), matching: find.text('1')), findsOneWidget);

      // Once the feed succeeds, returning clears the badge.
      failFeed = false;
      await tester.tap(find.byIcon(Icons.notifications_outlined));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(tester.widget<Badge>(find.byType(Badge)).isLabelVisible, isFalse);
    });

    test('aggregate attemptCount bump and persisted seen state compute unseen counts accurately', () async {
      final firstSeen = [Alert(id: 'a1', childId: 'c1', severity: 'critical', category: 'sos', title: 'SOS', body: '1 attempt', attemptCount: 1)];
      final notifier = AlertsSeenNotifier();
      await notifier.markFeedViewed(firstSeen, unackedTotalSnapshot: 1, unackedItemsSnapshot: firstSeen);

      expect(
        computeUnseenAlertCount(
          UnacknowledgedAlertsSummary(total: 1, items: firstSeen),
          notifier.state,
        ),
        0,
      );

      // Higher attemptCount (#227) marks an already-seen alert unseen again.
      final bumped = [Alert(id: 'a1', childId: 'c1', severity: 'critical', category: 'sos', title: 'SOS', body: '3 attempts', attemptCount: 3)];
      expect(
        computeUnseenAlertCount(
          UnacknowledgedAlertsSummary(total: 1, items: bumped),
          notifier.state,
        ),
        1,
      );

      // Reloaded notifier from SharedPreferences preserves seen state across restart.
      final reloaded = AlertsSeenNotifier();
      await reloaded.load();
      expect(reloaded.state.hasViewedFeed, isTrue);
      expect(
        computeUnseenAlertCount(
          UnacknowledgedAlertsSummary(total: 1, items: firstSeen),
          reloaded.state,
        ),
        0,
      );
      expect(
        computeUnseenAlertCount(
          UnacknowledgedAlertsSummary(total: 2, items: [
            ...firstSeen,
            Alert(id: 'a2', childId: 'c1', severity: 'warning', category: 'tamper', title: 'Tamper', body: 'New'),
          ]),
          reloaded.state,
        ),
        1,
      );
    });
  });
}
