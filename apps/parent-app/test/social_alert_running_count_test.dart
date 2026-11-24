import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
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
Future<bool> _loadSdkRobotoFont() async {
  final sep = Platform.pathSeparator;
  final candidates = <Directory>[
    Directory('test${sep}fonts'),
    Directory('apps${sep}parent-app${sep}test${sep}fonts'),
  ];
  Directory? fontsDir;
  for (final c in candidates) {
    if (c.existsSync()) {
      fontsDir = c;
      break;
    }
  }
  if (fontsDir == null) {
    Directory? dir = Directory(Platform.resolvedExecutable).parent;
    for (var i = 0; i < 8 && dir != null; i++) {
      final candidate = Directory('${dir.path}${sep}bin${sep}cache${sep}artifacts${sep}material_fonts');
      if (candidate.existsSync()) {
        fontsDir = candidate;
        break;
      }
      final directCandidate = Directory('${dir.path}${sep}material_fonts');
      if (directCandidate.existsSync()) {
        fontsDir = directCandidate;
        break;
      }
      final parent = dir.parent;
      if (parent.path == dir.path) break;
      dir = parent;
    }
    final envRoot = Platform.environment['FLUTTER_ROOT'];
    if (fontsDir == null && envRoot != null && envRoot.isNotEmpty) {
      final envCandidate = Directory('$envRoot${sep}bin${sep}cache${sep}artifacts${sep}material_fonts');
      if (envCandidate.existsSync()) fontsDir = envCandidate;
    }
  }
  if (fontsDir == null) return false;

  final loader = FontLoader('Roboto');
  var loadedCount = 0;
  for (final name in ['roboto-regular.ttf', 'roboto-medium.ttf', 'roboto-bold.ttf']) {
    final file = File('${fontsDir.path}$sep$name');
    if (file.existsSync()) {
      final bytes = await file.readAsBytes();
      loader.addFont(Future.value(ByteData.sublistView(bytes)));
      loadedCount++;
    }
  }
  if (loadedCount != 3) return false;
  await loader.load();
  return true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final t0905 = DateTime(2026, 11, 24, 9, 5);
  final t0910 = DateTime(2026, 11, 24, 9, 10);
  final t0915 = DateTime(2026, 11, 24, 9, 15);

  setUpAll(() async {
    await configureDateFormatting();
    final loaded = await _loadSdkRobotoFont();
    expect(loaded, isTrue, reason: 'SDK Roboto font must load so 200% metrics match device rendering');
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
    testWidgets('renders singular/plural titles, FSI contact line (1-line ellipsis), separate latest line, and unknown-contact fallback',
        (tester) async {
      // Mutant 1: hardcoding plural "messages" or wrapping contact in LRI instead of FSI breaks this test.
      // Mutant 2: omitting "an unknown contact" fallback when metadata['contact'] is blank fails the unknown check.
      // Mutant 3: merging contact and latest time onto one truncated line breaks the separate alert-latest-* line assertion.
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

      // Singular (=1) with named contact wrapped in first-strong isolate (FSI U+2068 ... PDI U+2069)
      expect(find.textContaining('1 concerning message on'), findsOneWidget);
      expect(find.text('From ${firstStrongIsolate('Alex Smith')}'), findsOneWidget);
      expect(find.text('Latest ${ltrIsolate('09:05')}'), findsOneWidget);

      // Plural (other) with unknown-contact fallback + separate latest line
      expect(find.textContaining('4 concerning messages on'), findsOneWidget);
      expect(find.text('From an unknown contact'), findsOneWidget);
      expect(find.text('Latest ${ltrIsolate('09:15')}'), findsOneWidget);
      expect(find.text('+2 new'), findsOneWidget);

      // Title allows maxLines 3; contact line enforces maxLines 2 + ellipsis (UI/UX 7117829072); latest line is unconstrained.
      final titleText = tester.widget<Text>(find.textContaining('1 concerning message on'));
      expect(titleText.maxLines, 3);
      final contactText = tester.widget<Text>(find.byKey(const ValueKey('alert-contact-a1')));
      expect(contactText.maxLines, 2);
      expect(contactText.overflow, TextOverflow.ellipsis);
      final latestText = tester.widget<Text>(find.byKey(const ValueKey('alert-latest-a1')));
      expect(latestText.maxLines, isNull);
      expect(latestText.overflow, isNull);

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

    test('reconciles out-of-order responses by freshness in both arrival orders while preserving legitimate updates', () {
      // Mutant: unconditional byId[a.id] = a lets an older response (count 1 @ 09:05) roll back
      // count 4 @ 09:15 and drop the card back below Contact B.
      final older = Alert.fromJson(socialAlertJson(
        id: 'a-contact-a',
        flaggedCount: 1,
        createdAt: t0905,
        latestAt: t0905,
        contactName: 'Contact A',
      ));
      final newer = Alert.fromJson(socialAlertJson(
        id: 'a-contact-a',
        flaggedCount: 4,
        createdAt: t0905,
        latestAt: t0915,
        contactName: 'Contact A',
      ));
      final contactB = Alert.fromJson(socialAlertJson(
        id: 'a-contact-b',
        flaggedCount: 2,
        createdAt: t0910,
        latestAt: t0910,
        contactName: 'Contact B',
      ));

      // Order 1: older arrives first, then newer -> count 4 at top.
      final inOrder = mergeAlertsInPlace(
        mergeAlertsInPlace(const [], [older, contactB]),
        [newer],
      );
      expect(inOrder.map((a) => a.id).toList(), ['a-contact-a', 'a-contact-b']);
      expect(inOrder.first.socialMessageCount, 4);

      // Order 2: newer arrives first, then stale older response arrives -> stays count 4 at top.
      final outOfOrder = mergeAlertsInPlace(
        mergeAlertsInPlace(const [], [newer, contactB]),
        [older],
      );
      expect(outOfOrder.map((a) => a.id).toList(), ['a-contact-a', 'a-contact-b']);
      expect(outOfOrder.first.socialMessageCount, 4);
      expect(outOfOrder.first.effectiveTimestamp, newer.effectiveTimestamp);

      // Same count but strictly older timestamp is also ignored.
      final sameCountOlderTs = Alert.fromJson(socialAlertJson(
        id: 'a-contact-a',
        flaggedCount: 4,
        createdAt: t0905,
        latestAt: t0905,
        contactName: 'Contact A',
      ));
      final afterStaleTs = mergeAlertsInPlace(outOfOrder, [sameCountOlderTs]);
      expect(afterStaleTs.first.effectiveTimestamp, newer.effectiveTimestamp);

      // Legitimate update at equal count & timestamp (e.g. acknowledged=true) is still applied.
      final ackedNewer = Alert.fromJson({
        ...socialAlertJson(
          id: 'a-contact-a',
          flaggedCount: 4,
          createdAt: t0905,
          latestAt: t0915,
          contactName: 'Contact A',
        ),
        'acknowledged': true,
      });
      final afterAck = mergeAlertsInPlace(outOfOrder, [ackedNewer]);
      expect(afterAck.first.acknowledged, isTrue);

      // Non-social alert updates remain unaffected.
      final otherV1 = Alert.fromJson(otherAlertJson(id: 'a-other', createdAt: t0910));
      final otherV2 = Alert.fromJson({
        ...otherAlertJson(id: 'a-other', createdAt: t0910),
        'acknowledged': true,
      });
      final afterOther = mergeAlertsInPlace([otherV1], [otherV2]);
      expect(afterOther.single.acknowledged, isTrue);
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
      expect(find.text('From ${firstStrongIsolate('Samira')}'), findsOneWidget);
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
      expect(find.text('From ${firstStrongIsolate('Samira')}'), findsOneWidget);

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
      expect(find.text('From ${firstStrongIsolate('Samira')}'), findsOneWidget);
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

  group('Feed card at 200% text scale in EN and AR (#1029, 7116306228, 7117829072)', () {
    for (final locale in const [Locale('en'), Locale('ar')]) {
      final isAr = locale.languageCode == 'ar';
      testWidgets('390px @ 2.0x (${locale.languageCode}): full app name, uncut latest time, long + unknown contact fit in 2 lines',
          (tester) async {
        // Mutant 1: setting maxLines: 1 on alert-contact-* truncates the unknown-contact fallback (didExceedMaxLines == true).
        // Mutant 2: merging contact + latest time onto one truncated Text or capping title below 3 lines cuts the app name or time.
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final longContact = isAr
            ? 'محمد عبدالله المنصوري العلي'
            : 'Mohammed Abdullah Al Mansouri';
        final longAlert = Alert.fromJson(socialAlertJson(
          id: 'scale-long',
          flaggedCount: 5,
          latestAt: t0915,
          contactName: longContact,
          app: 'whatsapp',
        ));
        final unknownAlert = Alert.fromJson(socialAlertJson(
          id: 'scale-unknown',
          flaggedCount: 1,
          latestAt: t0915,
          contactName: '   ',
          app: 'telegram',
        ));

        final baseTheme = AppTheme.light;
        final robotoTheme = baseTheme.copyWith(
          textTheme: baseTheme.textTheme.apply(fontFamily: 'Roboto'),
          primaryTextTheme: baseTheme.primaryTextTheme.apply(fontFamily: 'Roboto'),
        );

        await tester.pumpWidget(ProviderScope(
          child: MaterialApp(
            locale: locale,
            supportedLocales: AppLocalizations.supportedLocales,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            theme: robotoTheme,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(2.0)),
              child: child!,
            ),
            home: Scaffold(
              body: ListView(
                padding: const EdgeInsets.all(12),
                children: [
                  AlertTile(alert: longAlert, newSinceCount: 3, onAck: () {}),
                  AlertTile(alert: unknownAlert, onAck: () {}),
                ],
              ),
            ),
          ),
        ));
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);

        // 1. Title shows the app name in full without truncation on both cards.
        for (final appName in const ['WhatsApp', 'Telegram']) {
          final titleFinder = find.textContaining(appName);
          expect(titleFinder, findsOneWidget);
          final titleRender = tester.renderObject<RenderParagraph>(titleFinder);
          expect(titleRender.didExceedMaxLines, isFalse, reason: '$appName title must not truncate at 200%');
        }

        // 2. "Latest {time}" / "آخر رسالة {time}" is on its own line and never cut.
        for (final id in const ['scale-long', 'scale-unknown']) {
          final latestFinder = find.byKey(ValueKey('alert-latest-$id'));
          expect(latestFinder, findsOneWidget);
          final latestRender = tester.renderObject<RenderParagraph>(latestFinder);
          expect(latestRender.didExceedMaxLines, isFalse, reason: 'Latest time for $id must never be cut');
        }

        // 3. Long contact line enforces maxLines: 2 + ellipsis, and unknown-contact fallback fits in <= 2 lines uncut.
        final longContactWidget = tester.widget<Text>(find.byKey(const ValueKey('alert-contact-scale-long')));
        expect(longContactWidget.maxLines, 2);
        expect(longContactWidget.overflow, TextOverflow.ellipsis);

        final unknownContactFinder = find.byKey(const ValueKey('alert-contact-scale-unknown'));
        final unknownContactWidget = tester.widget<Text>(unknownContactFinder);
        expect(unknownContactWidget.maxLines, 2);
        final unknownRender = tester.renderObject<RenderParagraph>(unknownContactFinder);
        expect(
          unknownRender.didExceedMaxLines,
          isFalse,
          reason: 'Unknown-contact fallback must fit completely within 2 lines at 200%',
        );
      });
    }
  });
}
