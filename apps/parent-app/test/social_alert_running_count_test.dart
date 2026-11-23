import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:familyshield_parent/api/models.dart';
import 'package:familyshield_parent/core/date_formatting.dart';
import 'package:familyshield_parent/core/ltr_isolate.dart';
import 'package:familyshield_parent/features/alerts/alerts_screen.dart';
import 'package:familyshield_parent/features/children/child_detail_screen.dart' show AlertTile;
import 'package:familyshield_parent/l10n/l10n.dart';
import 'package:familyshield_parent/providers/auth_provider.dart';
import 'package:familyshield_parent/providers/family_provider.dart';
import 'package:familyshield_parent/theme/app_theme.dart';

import 'fake_api_client.dart';

/// #1029 (final per-contact UI/UX spec 7114262268): Parent app tests for per-contact
/// social alert running count, `ltrIsolate`-wrapped contact name or "an unknown contact",
/// 2+ contacts sitting side-by-side newest first, in-place update + move-to-top,
/// and "+N new" badge appearing after open and clearing on reopen.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final t0905 = DateTime(2026, 11, 24, 9, 5);
  final t0910 = DateTime(2026, 11, 24, 9, 10);
  final t0915 = DateTime(2026, 11, 24, 9, 15);

  setUpAll(() async {
    await configureDateFormatting();
  });

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  Map<String, dynamic> socialAlertJson({
    String id = 'alert-social-1',
    required int flaggedCount,
    required DateTime latestAt,
    DateTime? createdAt,
    String app = 'whatsapp',
    String? contactName = 'School Group',
  }) =>
      {
        'id': id,
        'childId': 'child-1',
        'deviceId': 'dev-1',
        'category': 'social_concern',
        'severity': 'warning',
        'title': 'Social concern in $app',
        'body': 'Flagged message on $app',
        'metadata': {
          'app': app,
          if (contactName != null) 'contact': contactName,
          'flaggedCount': flaggedCount,
          'latestAt': latestAt.toUtc().toIso8601String(),
          'concernTypes': ['cyberbullying'],
        },
        'createdAt': (createdAt ?? t0905).toUtc().toIso8601String(),
        'updatedAt': latestAt.toUtc().toIso8601String(),
        'acknowledged': false,
        'attemptCount': flaggedCount,
      };

  Map<String, dynamic> otherAlertJson({
    String id = 'alert-other-1',
    required DateTime createdAt,
  }) =>
      {
        'id': id,
        'childId': 'child-1',
        'deviceId': 'dev-1',
        'category': 'app_blocked',
        'severity': 'info',
        'title': 'Blocked app attempt',
        'body': 'Attempted to open TikTok',
        'metadata': <String, dynamic>{},
        'createdAt': createdAt.toUtc().toIso8601String(),
        'acknowledged': false,
      };

  Widget wrap(Widget child, {FakeApiClient? api}) {
    return ProviderScope(
      overrides: [
        if (api != null) apiClientProvider.overrideWithValue(api),
      ],
      child: MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: AppTheme.light,
        home: child,
      ),
    );
  }

  group('Per-contact social alert ICU plurals & contact name (#1029)', () {
    testWidgets('renders singular/plural titles, ltrIsolate contact name, unknown-contact fallback, and ellipsis',
        (tester) async {
      // Mutant 1: hardcoding plural "messages" or omitting ltrIsolate around contact name breaks this test.
      // Mutant 2: omitting "an unknown contact" fallback when metadata['contact'] is blank fails the unknown check.
      final singular = Alert.fromJson(socialAlertJson(
        id: 'a1',
        flaggedCount: 1,
        latestAt: t0905,
        contactName: 'Alex Smith',
      ));
      final pluralUnknown = Alert.fromJson(socialAlertJson(
        id: 'a2',
        flaggedCount: 4,
        latestAt: t0915,
        contactName: '   ',
      ));

      late AppLocalizations l10n;
      await tester.pumpWidget(wrap(
        Scaffold(
          body: Builder(builder: (ctx) {
            l10n = ctx.l10n;
            return ListView(
              children: [
                AlertTile(alert: singular),
                AlertTile(alert: pluralUnknown, newSinceCount: 2),
              ],
            );
          }),
        ),
      ));
      await tester.pumpAndSettle();

      // Singular (=1) with named contact wrapped in ltrIsolate
      expect(find.textContaining('1 concerning message on'), findsOneWidget);
      expect(find.textContaining('From ${ltrIsolate('Alex Smith')}'), findsOneWidget);
      expect(find.textContaining('09:05'), findsOneWidget);

      // Plural (other) with unknown-contact fallback
      expect(find.textContaining('4 concerning messages on'), findsOneWidget);
      expect(find.textContaining('From an unknown contact'), findsOneWidget);
      expect(find.textContaining('09:15'), findsOneWidget);
      expect(find.text('+2 new'), findsOneWidget);

      // Subtitle enforces single-line ellipsis (7114262268 rule 1).
      final subtitleText = tester.widget<Text>(find.textContaining('From ${ltrIsolate('Alex Smith')}'));
      expect(subtitleText.maxLines, 1);
      expect(subtitleText.overflow, TextOverflow.ellipsis);

      // Follow-up push ICU plurals (=1 and other) never carry a contact name (lock-screen privacy).
      expect(
        l10n.socialAlertMorePush(1, 'Alex', 'WhatsApp'),
        '1 more concerning message for Alex on WhatsApp',
      );
      expect(
        l10n.socialAlertMorePush(3, 'Alex', 'WhatsApp'),
        '3 more concerning messages for Alex on WhatsApp',
      );
      expect(l10n.socialAlertNewSince(2), '+2 new');
    });
  });

  group('mergeAlertsInPlace (#1029)', () {
    test('updates existing contact card in place without duplicating and keeps 2 contacts newest-first', () {
      // Mutant: ignoring existing ids (old _loadMore behavior) or sorting by createdAt instead of
      // effectiveTimestamp leaves a stale count or wrong order.
      final contactA = Alert.fromJson(socialAlertJson(
        id: 'a-contact-a',
        flaggedCount: 1,
        createdAt: t0905,
        latestAt: t0905,
        contactName: 'Contact A',
      ));
      final contactB = Alert.fromJson(socialAlertJson(
        id: 'a-contact-b',
        flaggedCount: 2,
        createdAt: t0910,
        latestAt: t0910,
        contactName: 'Contact B',
      ));

      final initial = mergeAlertsInPlace(const [], [contactA, contactB]);
      expect(initial.map((a) => a.id).toList(), ['a-contact-b', 'a-contact-a']);

      // Contact A receives 3 more messages -> updates in place and moves above Contact B.
      final updatedContactA = Alert.fromJson(socialAlertJson(
        id: 'a-contact-a',
        flaggedCount: 4,
        createdAt: t0905,
        latestAt: t0915,
        contactName: 'Contact A',
      ));
      final merged = mergeAlertsInPlace(initial, [updatedContactA]);
      expect(merged.length, 2);
      expect(merged.map((a) => a.id).toList(), ['a-contact-a', 'a-contact-b']);
      expect(merged.first.socialMessageCount, 4);
      expect(merged.first.socialContactName, 'Contact A');
    });
  });

  group('AlertsScreen per-contact in-place update, move-to-top, and +N new badge (#1029)', () {
    testWidgets('updates card in place, moves it to top, shows +2 new after open, and clears on reopen',
        (tester) async {
      // Mutant 1: failing to clear "+2 new" when reopening leaves find.text('+2 new') present.
      // Mutant 2: showing "+N new" before the parent has ever opened the alert fails the initial check.
      // Mutant 3: sorting by createdAt instead of latestAt leaves alert-social-1 below alert-other-1.
      var currentAlerts = <Map<String, dynamic>>[
        otherAlertJson(id: 'alert-other-1', createdAt: t0910),
        socialAlertJson(
          id: 'alert-social-1',
          flaggedCount: 2,
          createdAt: t0905,
          latestAt: t0905,
          contactName: 'Samira',
        ),
      ];

      final api = FakeApiClient({
        ...standardRoutes(),
        'GET /v1/alerts': (_) => {
              'items': currentAlerts,
              'meta': {'total': currentAlerts.length, 'page': 1, 'limit': 20},
            },
        'GET /v1/social/events': (_) => {
              'items': [
                {
                  'id': 'evt-1',
                  'childId': 'child-1',
                  'app': 'whatsapp',
                  'contact': 'Samira',
                  'severity': 'warning',
                  'concernTypes': ['cyberbullying'],
                  'preview': 'Vault only',
                  'createdAt': t0905.toUtc().toIso8601String(),
                },
              ],
            },
      });

      await tester.pumpWidget(wrap(
        AlertsScreen(nowProvider: () => t0915),
        api: api,
      ));
      await tester.pumpAndSettle();

      // Initially: alert-other-1 (09:10) is above alert-social-1 (09:05), and NO "+N new" badge yet.
      expect(find.byKey(const ValueKey('alert-card-alert-social-1')), findsOneWidget);
      expect(find.textContaining('2 concerning messages on'), findsOneWidget);
      expect(find.textContaining('From ${ltrIsolate('Samira')}'), findsOneWidget);
      expect(find.byKey(const ValueKey('alert-new-since-alert-social-1')), findsNothing);
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('alert-card-alert-other-1'))).dy,
        lessThan(tester.getTopLeft(find.byKey(const ValueKey('alert-card-alert-social-1'))).dy),
      );

      // Parent opens alert-social-1 at count 2 -> detail shows running count title & per-contact subtitle.
      await tester.tap(find.byKey(const ValueKey('alert-card-alert-social-1')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('alertDetailTitle')), findsOneWidget);
      expect(find.textContaining('2 concerning messages on'), findsOneWidget);
      expect(find.byKey(const ValueKey('alertDetailCountSub')), findsOneWidget);
      expect(find.textContaining('From ${ltrIsolate('Samira')}'), findsOneWidget);

      // Return to feed.
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('alert-new-since-alert-social-1')), findsNothing);

      // 2 more flagged messages arrive from Samira in the same window (total 4, latest 09:15).
      currentAlerts = [
        otherAlertJson(id: 'alert-other-1', createdAt: t0910),
        socialAlertJson(
          id: 'alert-social-1',
          flaggedCount: 4,
          createdAt: t0905,
          latestAt: t0915,
          contactName: 'Samira',
        ),
      ];

      // Pull to refresh on AlertsScreen.
      await tester.fling(find.byType(ListView), const Offset(0, 400), 1000);
      await tester.pumpAndSettle();

      // Single card updated in place, moved to top above alert-other-1, showing "+2 new".
      expect(find.byKey(const ValueKey('alert-card-alert-social-1')), findsOneWidget);
      expect(find.textContaining('4 concerning messages on'), findsOneWidget);
      expect(find.textContaining('From ${ltrIsolate('Samira')}'), findsOneWidget);
      expect(find.textContaining('09:15'), findsOneWidget);
      expect(find.byKey(const ValueKey('alert-new-since-alert-social-1')), findsOneWidget);
      expect(find.text('+2 new'), findsOneWidget);
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('alert-card-alert-social-1'))).dy,
        lessThan(tester.getTopLeft(find.byKey(const ValueKey('alert-card-alert-other-1'))).dy),
      );

      // Parent re-opens alert-social-1 -> "+2 new" clears when returning to feed.
      await tester.tap(find.byKey(const ValueKey('alert-card-alert-social-1')));
      await tester.pumpAndSettle();
      expect(find.textContaining('4 concerning messages on'), findsOneWidget);
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('alert-new-since-alert-social-1')), findsNothing);
    });

    testWidgets('updates open feed in place, moves to top, and shows +2 new WITHOUT a gesture (bounded refresh + ws invalidation)',
        (tester) async {
      // Mutant: removing the bounded periodic refresh timer or alertsProvider listener in
      // AlertsScreen leaves the open feed stuck at count 2 when simulated time advances without a gesture.
      var currentAlerts = <Map<String, dynamic>>[
        otherAlertJson(id: 'alert-other-1', createdAt: t0910),
        socialAlertJson(
          id: 'alert-social-1',
          flaggedCount: 2,
          createdAt: t0905,
          latestAt: t0905,
          contactName: 'Samira',
        ),
      ];

      final api = FakeApiClient({
        ...standardRoutes(),
        'GET /v1/alerts': (_) => {
              'items': currentAlerts,
              'meta': {'total': currentAlerts.length, 'page': 1, 'limit': 20},
            },
        'GET /v1/social/events': (_) => {
              'items': [
                {
                  'id': 'evt-1',
                  'childId': 'child-1',
                  'app': 'whatsapp',
                  'contact': 'Samira',
                  'severity': 'warning',
                  'concernTypes': ['cyberbullying'],
                  'preview': 'Vault only',
                  'createdAt': t0905.toUtc().toIso8601String(),
                },
              ],
            },
      });

      final container = ProviderContainer(
        overrides: [apiClientProvider.overrideWithValue(api)],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: AppTheme.light,
          home: AlertsScreen(nowProvider: () => t0915),
        ),
      ));
      await tester.pumpAndSettle();

      // Open alert-social-1 at count 2 and return to the open feed.
      await tester.tap(find.byKey(const ValueKey('alert-card-alert-social-1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('alert-new-since-alert-social-1')), findsNothing);

      // 2 more messages arrive on the server; advance 1 minute of simulated time with NO gesture.
      currentAlerts = [
        otherAlertJson(id: 'alert-other-1', createdAt: t0910),
        socialAlertJson(
          id: 'alert-social-1',
          flaggedCount: 4,
          createdAt: t0905,
          latestAt: t0915,
          contactName: 'Samira',
        ),
      ];
      await tester.pump(const Duration(minutes: 1));
      await tester.pumpAndSettle();

      // Open feed updated in place, moved above alert-other-1, and shows "+2 new" without a gesture.
      expect(find.byKey(const ValueKey('alert-card-alert-social-1')), findsOneWidget);
      expect(find.textContaining('4 concerning messages on'), findsOneWidget);
      expect(find.byKey(const ValueKey('alert-new-since-alert-social-1')), findsOneWidget);
      expect(find.text('+2 new'), findsOneWidget);
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('alert-card-alert-social-1'))).dy,
        lessThan(tester.getTopLeft(find.byKey(const ValueKey('alert-card-alert-other-1'))).dy),
      );

      // Realtime alertsProvider invalidation path updates immediately to count 5 (+3 new) without a gesture.
      currentAlerts = [
        otherAlertJson(id: 'alert-other-1', createdAt: t0910),
        socialAlertJson(
          id: 'alert-social-1',
          flaggedCount: 5,
          createdAt: t0905,
          latestAt: t0915.add(const Duration(minutes: 1)),
          contactName: 'Samira',
        ),
      ];
      container.invalidate(alertsProvider);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pumpAndSettle();

      expect(find.textContaining('5 concerning messages on'), findsOneWidget);
      expect(find.text('+3 new'), findsOneWidget);
    });
  });
}
