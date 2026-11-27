import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geocoding/geocoding.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:familyshield_parent/api/models.dart';
import 'package:familyshield_parent/features/alerts/alert_detail_screen.dart';
import 'package:familyshield_parent/features/alerts/alerts_screen.dart';
import 'package:familyshield_parent/features/children/child_detail_screen.dart';
import 'package:familyshield_parent/features/dashboard/dashboard_screen.dart';
import 'package:familyshield_parent/features/dashboard/home_p07_screen.dart';
import 'package:familyshield_parent/features/family/family_screen.dart';
import 'package:familyshield_parent/features/map/child_location_view.dart';
import 'package:familyshield_parent/l10n/app_localizations.dart';
import 'package:familyshield_parent/providers/auth_provider.dart';
import 'package:familyshield_parent/providers/clock_provider.dart';
import 'package:familyshield_parent/providers/onboarding_provider.dart';
import 'package:familyshield_parent/providers/pairing_session_provider.dart';
import 'package:familyshield_parent/theme/app_theme.dart';

import 'fake_api_client.dart';

Future<void> _loadFonts() async {
  Future<void> load(String family, List<String> paths) async {
    final loader = FontLoader(family);
    var count = 0;
    for (final p in paths) {
      final f = File(p);
      if (f.existsSync()) {
        loader.addFont(Future.value(ByteData.sublistView(f.readAsBytesSync())));
        count++;
      }
    }
    if (count > 0) await loader.load();
  }

  final sdk = Platform.environment['FLUTTER_ROOT'] ?? 'C:/KARIM/tools/flutter';
  await load('Roboto', [
    'test/fonts/roboto-regular.ttf',
    'test/fonts/roboto-medium.ttf',
    'test/fonts/roboto-bold.ttf',
  ]);
  await load('NotoNaskhArabic', [
    '$sdk/engine/src/flutter/txt/third_party/fonts/NotoNaskhArabic-Regular.ttf',
  ]);
  await load('MaterialIcons', [
    '$sdk/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
  ]);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await _loadFonts();
  });

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({kOnboardingCompleteKey: true});
  });

  final weekdayNow = DateTime.utc(2026, 11, 26, 12, 30); // Thursday 16:30 UAE
  const frameBoundaryKey = ValueKey('p07FrameRepaintBoundary');

  List<Object> drainExceptions(WidgetTester tester) {
    final exceptions = <Object>[];
    while (true) {
      final e = tester.takeException();
      if (e == null) return exceptions;
      exceptions.add(e);
    }
  }

  Future<void> flushHttp(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Finder homeVerticalScrollable() => find.descendant(
        of: find.byKey(const ValueKey('p07HomeList')),
        matching: find.byType(Scrollable),
      );

  Map<String, FakeRoute> p07Routes({
    Map<String, dynamic>? familyMe,
    List<Map<String, dynamic>>? alerts,
  }) {
    final items = alerts ?? const <Map<String, dynamic>>[];
    return {
      ...standardRoutes(familyMe: familyMe, alerts: items, unacked: items.length),
      'GET /v1/controls/children/child-1/status': (_) => {'paused': false},
      'GET /v1/controls/children/child-2/status': (_) => {'paused': false},
      'GET /v1/alerts': (req) {
        if (req.query['ack'] == 'false') {
          final unackedItems =
              items.where((a) => a['acknowledged'] != true).toList();
          return {
            'items': unackedItems,
            'total': unackedItems.length,
            'page': 1,
            'limit': 50,
            'meta': {'total': unackedItems.length, 'page': 1, 'limit': 50},
          };
        }
        return {
          'items': items,
          'total': items.length,
          'page': 1,
          'limit': 50,
        };
      },
    };
  }

  Widget buildP07App({
    required FakeApiClient api,
    Locale locale = const Locale('en'),
    ThemeMode themeMode = ThemeMode.light,
    double textScale = 1.0,
    Size size = const Size(390, 844),
    bool p07Enabled = true,
    Duration bonusHold = const Duration(seconds: 5),
    DateTime? now,
    ActivePairingSession? activePairing,
  }) {
    final router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(
          path: '/',
          builder: (_, __) => const DashboardScreen(),
          routes: [
            GoRoute(
              path: 'alerts',
              builder: (_, __) => const AlertsScreen(),
              routes: [
                GoRoute(
                  path: ':id',
                  builder: (_, s) => AlertDetailScreen(
                    alertId: s.pathParameters['id']!,
                    initialAlert: s.extra is Alert ? s.extra as Alert : null,
                  ),
                ),
              ],
            ),
          ],
        ),
        GoRoute(
          path: '/child/:id',
          builder: (_, s) =>
              ChildDetailScreen(childId: s.pathParameters['id']!),
        ),
      ],
    );

    return ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        p07HomeEnabledProvider.overrideWithValue(p07Enabled),
        p07BonusHoldDurationProvider.overrideWithValue(bonusHold),
        clockProvider.overrideWithValue(() => now ?? weekdayNow),
        if (activePairing != null)
          activePairingSessionProvider.overrideWith((_) => activePairing),
        placemarkLookupProvider.overrideWithValue(
          (lat, lng, loc) async => [
            Placemark(
              subLocality: loc.languageCode == 'ar' ? 'البرشاء' : 'Al Barsha',
              locality: loc.languageCode == 'ar' ? 'دبي' : 'Dubai',
            ),
          ],
        ),
      ],
      child: RepaintBoundary(
        key: frameBoundaryKey,
        child: MaterialApp.router(
          debugShowCheckedModeBanner: false,
          locale: locale,
          theme: AppTheme.light.copyWith(
            textTheme: AppTheme.light.textTheme.apply(
              fontFamily: 'Roboto',
              fontFamilyFallback: const ['NotoNaskhArabic'],
            ),
          ),
          darkTheme: AppTheme.dark.copyWith(
            textTheme: AppTheme.dark.textTheme.apply(
              fontFamily: 'Roboto',
              fontFamilyFallback: const ['NotoNaskhArabic'],
            ),
          ),
          themeMode: themeMode,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          routerConfig: router,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              size: size,
              textScaler: TextScaler.linear(textScale),
            ),
            child: Directionality(
              textDirection: locale.languageCode == 'ar'
                  ? TextDirection.rtl
                  : TextDirection.ltr,
              child: child!,
            ),
          ),
        ),
      ),
    );
  }

  group('G5 time-left formula & honest state words', () {
    /// Mutant: read `ruleSet.bonusMinutesToday` (which never resets on the server)
    /// and `effectiveLimitMinutes` jumps from 120 to 210 on a day with 0 acked grants.
    test('ignores stale ruleSet.bonusMinutesToday and counts only today acked bonus_time commands', () {
      final rules = RuleSet.fromJson({
        'bonusMinutesToday': 90,
        'screenTime': {'dailyLimitMinutes': 120, 'weekendLimitMinutes': 180},
      });
      final summaryWithoutAck = computeHomeTimeSummary(
        usedMinutes: 45,
        rules: rules,
        now: weekdayNow,
        utcOffsetMinutes: 240,
        primaryDeviceHistory: [
          DeviceCommand(
            id: 'cmd-pending',
            deviceId: 'dev-1',
            type: 'bonus_time',
            status: 'pending',
            payload: const {'minutes': 30},
            createdAt: weekdayNow,
          ),
          DeviceCommand(
            id: 'cmd-yesterday',
            deviceId: 'dev-1',
            type: 'bonus_time',
            status: 'acked',
            payload: const {'minutes': 30},
            ackedAt: weekdayNow.subtract(const Duration(days: 1)),
          ),
        ],
      );
      expect(summaryWithoutAck.effectiveLimitMinutes, 120);
      expect(summaryWithoutAck.remainingMinutes, 75);

      final summaryWithTodayAck = computeHomeTimeSummary(
        usedMinutes: 45,
        rules: rules,
        now: weekdayNow,
        utcOffsetMinutes: 240,
        primaryDeviceHistory: [
          DeviceCommand(
            id: 'cmd-today-acked',
            deviceId: 'dev-1',
            type: 'bonus_time',
            status: 'acked',
            payload: const {'minutes': 15},
            ackedAt: weekdayNow.subtract(const Duration(minutes: 10)),
          ),
        ],
      );
      expect(summaryWithTodayAck.effectiveLimitMinutes, 135);
      expect(summaryWithTodayAck.remainingMinutes, 90);
    });

    /// Mutant: use `dailyLimitMinutes` on Saturday/Sunday and `effectiveLimitMinutes`
    /// returns 120 instead of 180.
    test('uses weekendLimitMinutes on Saturday and Sunday when positive', () {
      const rules = RuleSet(
        screenTime:
            ScreenTimeRule(dailyLimitMinutes: 120, weekendLimitMinutes: 180),
      );
      final saturdayUtc = DateTime.utc(2026, 11, 28, 10, 0); // Saturday
      final sat = computeHomeTimeSummary(
        usedMinutes: 60,
        rules: rules,
        now: saturdayUtc,
        utcOffsetMinutes: 240,
        primaryDeviceHistory: const [],
      );
      expect(sat.effectiveLimitMinutes, 180);
      expect(sat.remainingMinutes, 120);
    });

    /// Mutant: fall back to `ruleSet.bonusMinutesToday` when a same-day grant ages
    /// out of `primaryDeviceHistory`, inflating `effectiveLimitMinutes` from stale
    /// cross-day server state instead of conservatively clamping `remainingMinutes` at 0.
    test('conservatively drops a grant that aged out of the bounded history window and clamps remaining at 0', () {
      final rules = RuleSet.fromJson({
        'bonusMinutesToday': 60,
        'screenTime': {'dailyLimitMinutes': 120, 'weekendLimitMinutes': 180},
      });
      final boundedWindow = List<DeviceCommand>.generate(
        100,
        (i) => DeviceCommand(
          id: 'cmd-newer-$i',
          deviceId: 'dev-1',
          type: 'locate_now',
          status: 'acked',
          ackedAt: weekdayNow.subtract(Duration(seconds: i)),
        ),
      );
      final agedOut = computeHomeTimeSummary(
        usedMinutes: 130,
        rules: rules,
        now: weekdayNow,
        utcOffsetMinutes: 240,
        primaryDeviceHistory: boundedWindow,
      );
      expect(agedOut.effectiveLimitMinutes, 120);
      expect(agedOut.remainingMinutes, 0);
      expect(agedOut.progress, 1.0);
    });
  });

  group('Feature switch & excluded anti-patterns', () {
    /// Mutant: drop the `p07HomeEnabledProvider` check in `DashboardScreen.build`
    /// and the fallback renders `HomeP07Screen` even when the switch is false.
    testWidgets('switch off renders legacy DashboardScreen; switch on renders HomeP07Screen without wellbeing or swipe', (tester) async {
      final api = FakeApiClient({
        ...p07Routes(),
        'GET /v1/reports/wellbeing/child-1': (_) => {
              'childId': 'child-1',
              'score': 85,
              'components': {'screenTime': 90, 'social': 80, 'safety': 85},
            },
        'GET /v1/reports/wellbeing/child-2': (_) => {
              'childId': 'child-2',
              'score': 92,
              'components': {'screenTime': 92, 'social': 92, 'safety': 92},
            },
      });

      await tester.pumpWidget(buildP07App(api: api, p07Enabled: false));
      await flushHttp(tester);
      await tester.pumpAndSettle();
      expect(find.byType(HomeP07Screen), findsNothing);
      expect(find.byKey(const ValueKey('dashboardCardsList')), findsOneWidget);

      await tester.pumpWidget(buildP07App(api: api, p07Enabled: true));
      await flushHttp(tester);
      await tester.pumpAndSettle();
      expect(find.byType(HomeP07Screen), findsOneWidget);
      expect(find.textContaining('Wellbeing'), findsNothing);
      expect(find.byType(PageView), findsNothing);
      expect(find.textContaining('Ask OSRA'), findsNothing);
    });
  });

  group('Child filter chips, Needs you (A9, A10, requests, safety alerts), and 4 tabs', () {
    /// Mutant: default `_selectedChildId` to the first child instead of `null` (`All`)
    /// and Sam's card disappears on initial open.
    testWidgets('All chip is default and tapping a child chip filters to that child only', (tester) async {
      final api = FakeApiClient(p07Routes());
      await tester.pumpWidget(buildP07App(api: api));
      await flushHttp(tester);
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('homeChildCard-child-1')), findsOneWidget);
      expect(find.byKey(const ValueKey('homeChildCard-child-2')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('homeFilterChip-child-1')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('homeChildCard-child-1')), findsOneWidget);
      expect(find.byKey(const ValueKey('homeChildCard-child-2')), findsNothing);

      await tester.tap(find.byKey(const ValueKey('homeFilterChip-all')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('homeChildCard-child-2')), findsOneWidget);
    });

    /// Mutant: ack the safety alert on tapping `Review` instead of navigating to `/alerts/:id`
    /// and `POST /v1/alerts/:id/ack` fires without parent review.
    testWidgets('Needs you renders A9 MFA reset, A10 pairing claim, requests (no note, no 1h), and Review navigation', (tester) async {
      final api = FakeApiClient({
        ...p07Routes(
          alerts: [
            {
              'id': 'req-time-1',
              'childId': 'child-1',
              'deviceId': 'dev-1',
              'severity': 'info',
              'category': 'app_blocked',
              'title': 'Time request',
              'body': 'Body',
              'metadata': {
                'requestType': 'time',
                'reason': 'daily_limit',
                'minutes': '30',
                'packageId': 'com.mojang.minecraftpe',
                'note': 'please dad',
              },
              'createdAt': weekdayNow.toIso8601String(),
              'acknowledged': false,
            },
            {
              'id': 'req-app-1',
              'childId': 'child-1',
              'severity': 'info',
              'category': 'app_blocked',
              'title': 'App request',
              'body': 'Body',
              'metadata': {
                'requestType': 'access',
                'packageId': 'com.roblox.client',
                'appName': 'Roblox',
              },
              'createdAt': weekdayNow.toIso8601String(),
              'acknowledged': false,
            },
            {
              'id': 'urgent-1',
              'childId': 'child-2',
              'severity': 'critical',
              'category': 'sos',
              'title': 'SOS pressed',
              'body': 'SOS body',
              'createdAt': weekdayNow.toIso8601String(),
              'acknowledged': false,
            },
          ],
        ),
        'GET /v1/auth/mfa/reset/pending': (_) => {
              'requests': [
                {
                  'requestId': 'rst-1',
                  'requesterName': 'Fatima',
                  'requesterRole': 'co-parent',
                  'state': 'witness_pending',
                  'windowEndsAt': weekdayNow
                      .add(const Duration(minutes: 10))
                      .toIso8601String(),
                },
              ],
            },
        'GET /v1/devices/pair/482916/claim': (_) => {
              'status': 'pending',
              'claimId': 'claim-1',
              'platform': 'android',
              'model': 'Galaxy A54',
              'osVersion': '14',
            },
        'POST /v1/devices/pair/claims/claim-1/approve': (_) => {'ok': true},
        'POST /v1/alerts/req-time-1/ack': (_) => {'ok': true},
        'POST /v1/alerts/req-app-1/ack': (_) => {'ok': true},
      });

      await tester.pumpWidget(
        buildP07App(
          api: api,
          activePairing: ActivePairingSession(
            code: '482916',
            childId: 'child-1',
            expiresAt: weekdayNow.add(const Duration(minutes: 5)),
          ),
        ),
      );
      await flushHttp(tester);
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('homeNeedsYouSection')), findsOneWidget);
      expect(find.byKey(const ValueKey('mfaResetPendingBanner')), findsOneWidget);
      expect(find.byKey(const ValueKey('homePairingClaimBanner')), findsOneWidget);

      // Karim 17:02 & 17:04 + P-20 (#1200): whole-day screen time wording, zero child note, zero "Allow 1 hour".
      expect(find.textContaining('asked for 30 more minutes today'), findsOneWidget);
      expect(find.textContaining('please dad'), findsNothing);
      expect(find.textContaining('Allow 1 hour'), findsNothing);
      expect(find.byKey(const ValueKey('homeReqAllow-req-app-1')), findsOneWidget);
      expect(find.byKey(const ValueKey('homeReqKeepBlocked-req-app-1')), findsOneWidget);

      // Approve A10 pairing claim right from Home.
      await tester.tap(find.byKey(const ValueKey('homePairClaimAllow')));
      await flushHttp(tester);
      await tester.pumpAndSettle();
      expect(api.calls('POST', '/v1/devices/pair/claims/claim-1/approve'), hasLength(1));

      // Safety alert Review navigates to detail and NEVER auto-acks.
      final reviewBtn = find.byKey(const ValueKey('homeSafetyAlertsReviewButton'));
      await tester.scrollUntilVisible(
        reviewBtn,
        120,
        scrollable: homeVerticalScrollable(),
      );
      await tester.pumpAndSettle();
      await tester.tap(reviewBtn);
      await flushHttp(tester);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDetailScreen), findsOneWidget);
      expect(api.calls('POST', '/v1/alerts/urgent-1/ack'), isEmpty);
    });

    /// Mutant: read `GET /v1/devices/pair/:code/claim` only once on mount without
    /// scheduling a waiting poll, and `homePairingClaimBanner` remains absent
    /// after the child claims the code while Home is already open.
    testWidgets('A10 live arrival: pairing claim starting as waiting advances to pending on Home without manual refresh', (tester) async {
      var claimState = <String, dynamic>{'status': 'waiting'};
      final api = FakeApiClient({
        ...p07Routes(),
        'GET /v1/devices/pair/482916/claim': (_) => claimState,
      });

      await tester.pumpWidget(
        buildP07App(
          api: api,
          activePairing: ActivePairingSession(
            code: '482916',
            childId: 'child-1',
            expiresAt: weekdayNow.add(const Duration(minutes: 5)),
          ),
        ),
      );
      await flushHttp(tester);
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('homePairingClaimBanner')), findsNothing);

      claimState = <String, dynamic>{
        'status': 'pending',
        'claimId': 'claim-live-1',
        'platform': 'android',
        'model': 'Pixel 8a',
        'osVersion': '15',
      };

      await tester.pump(const Duration(seconds: 2));
      await flushHttp(tester);
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('homePairingClaimBanner')), findsOneWidget);
      expect(find.textContaining('Pixel 8a'), findsOneWidget);
    });

    /// Mutant: call `POST /v1/controls/children/:id/bonus` + `POST /v1/alerts/:id/ack`
    /// from Home instead of `POST /v1/alerts/:id/time-decision`, or drop the card on
    /// `unacknowledgedAlertsProvider` refresh before showing a 409 winning caregiver receipt.
    testWidgets('G4 + P-20 on Home: +15, +30, Not today use POST /v1/alerts/:id/time-decision and 409 displays winning caregiver receipt', (tester) async {
      var timeResolvedOnServer = false;
      final alertsList = <Map<String, dynamic>>[
        {
          'id': 'req-decide-1',
          'childId': 'child-1',
          'deviceId': 'dev-1',
          'severity': 'info',
          'category': 'app_blocked',
          'title': 'Time request',
          'body': 'Body',
          'metadata': {
            'requestType': 'time',
            'reason': 'daily_limit',
            'minutes': '15',
          },
          'createdAt': weekdayNow.toIso8601String(),
          'acknowledged': false,
        },
      ];

      final api = FakeApiClient({
        ...p07Routes(alerts: alertsList),
        'GET /v1/alerts': (req) {
          final visible = req.query['ack'] == 'false' && timeResolvedOnServer
              ? const <Map<String, dynamic>>[]
              : alertsList;
          return {
            'items': visible,
            'total': visible.length,
            'page': 1,
            'limit': 50,
            'meta': {'total': visible.length, 'page': 1, 'limit': 50},
          };
        },
        'POST /v1/alerts/req-decide-1/time-decision': (_) {
          timeResolvedOnServer = true;
          return const FakeHttpError(409, {
            'error': 'time_request_already_resolved',
            'resolution': {
              'action': 'grant',
              'minutes': 30,
              'actorName': 'Sarah',
              'resolvedAt': '2026-11-26T12:28:00Z',
            },
          });
        },
      });

      await tester.pumpWidget(buildP07App(api: api));
      await flushHttp(tester);
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('time-request-grant-15')), findsOneWidget);
      expect(find.byKey(const ValueKey('time-request-grant-30')), findsOneWidget);
      expect(find.byKey(const ValueKey('time-request-decline')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('time-request-grant-15')));
      await flushHttp(tester);
      await tester.pumpAndSettle();

      final decisionCalls = api.calls('POST', '/v1/alerts/req-decide-1/time-decision');
      expect(decisionCalls, hasLength(1));
      expect(decisionCalls.single.body, {'action': 'grant', 'minutes': 15});
      expect(api.calls('POST', '/v1/controls/children/child-1/bonus'), isEmpty);
      expect(api.calls('POST', '/v1/alerts/req-decide-1/ack'), isEmpty);

      expect(find.byKey(const ValueKey('time-request-receipt')), findsOneWidget);
      expect(find.textContaining('Sarah'), findsOneWidget);
      expect(find.textContaining('already gave 30 minutes today'), findsOneWidget);
      expect(find.byKey(const ValueKey('time-request-grant-15')), findsNothing);
    });

    /// Mutant: omit `FamilyScreen` or settings items on tabs 2 and 3 (A21, A22, A29)
    /// and invited members / MFA / digests become unreachable from P-07.
    testWidgets('4-tab bar switches cleanly between Home, Alerts, Family, and Settings', (tester) async {
      final api = FakeApiClient({
        ...p07Routes(),
        'GET /v1/family/invites': (_) => {'items': <dynamic>[]},
      });
      await tester.pumpWidget(buildP07App(api: api));
      await flushHttp(tester);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('p07Tab-family')));
      await flushHttp(tester);
      await tester.pumpAndSettle();
      expect(find.byType(FamilyScreen), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('p07Tab-settings')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('homeSettingsAppearance')), findsOneWidget);
      expect(find.byKey(const ValueKey('homeSettingsDigests')), findsOneWidget);
      expect(find.byKey(const ValueKey('homeSettingsMfa')), findsOneWidget);
      expect(find.byKey(const ValueKey('homeSettingsDeleteAccount')), findsOneWidget);
    });
  });

  group('G4 bonus hold-to-Undo, Karim Pause internet + Lock model, and G6 iPhone', () {
    /// Mutant: send `POST /v1/controls/children/:id/bonus` immediately on tap
    /// instead of holding, and tapping Undo still leaves a server bonus call recorded.
    testWidgets('G4: +15 min holds for 5s, Undo cancels locally with 0 POSTs, elapsed sends 1 POST', (tester) async {
      final api = FakeApiClient({
        ...p07Routes(),
        'POST /v1/controls/children/child-1/bonus': (_) => ruleSetPayload('child-1'),
      });
      await tester.pumpWidget(buildP07App(api: api, bonusHold: const Duration(seconds: 5)));
      await flushHttp(tester);
      await tester.pumpAndSettle();

      final plus15 = find.byKey(const ValueKey('homeActionPlus15-child-1'));
      await tester.scrollUntilVisible(
        plus15,
        120,
        scrollable: homeVerticalScrollable(),
      );
      await tester.pumpAndSettle();
      await tester.tap(plus15);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(api.calls('POST', '/v1/controls/children/child-1/bonus'), isEmpty);
      await tester.tap(find.widgetWithText(SnackBarAction, 'Undo'));
      await tester.pump(const Duration(seconds: 6));
      expect(api.calls('POST', '/v1/controls/children/child-1/bonus'), isEmpty);

      // Second tap without Undo -> sends after 5s hold.
      await tester.tap(plus15);
      await tester.pump(const Duration(seconds: 5));
      await flushHttp(tester);
      await tester.pumpAndSettle();
      expect(api.calls('POST', '/v1/controls/children/child-1/bonus'), hasLength(1));
      expect(find.byKey(const ValueKey('homeSentToPhone-child-1')), findsOneWidget);
    });

    /// Mutant: wire child-card Lock to pause or omit Undo unlock, and device
    /// command calls fail to record `lock` followed by `unlock`.
    testWidgets('Pause internet + Undo and child-wide Lock + Undo dispatch real API calls', (tester) async {
      final api = FakeApiClient({
        ...p07Routes(),
        'POST /v1/controls/children/child-1/pause': (_) =>
            {'childId': 'child-1', 'paused': true},
        'POST /v1/controls/children/child-1/resume': (_) =>
            {'childId': 'child-1', 'paused': false},
        'POST /v1/devices/dev-1/command': (req) => {
              'id': 'cmd-1',
              'status': 'pending',
              'command': req.body['command'],
            },
      });
      await tester.pumpWidget(buildP07App(api: api));
      await flushHttp(tester);
      await tester.pumpAndSettle();

      final pauseBtn =
          find.byKey(const ValueKey('homeActionPauseInternet-child-1'));
      await tester.scrollUntilVisible(
        pauseBtn,
        120,
        scrollable: homeVerticalScrollable(),
      );
      await tester.pumpAndSettle();
      await tester.tap(pauseBtn);
      await flushHttp(tester);
      await tester.pump();
      expect(api.calls('POST', '/v1/controls/children/child-1/pause'), hasLength(1));

      await tester.tap(find.text('Undo').last);
      await flushHttp(tester);
      await tester.pumpAndSettle();
      expect(api.calls('POST', '/v1/controls/children/child-1/resume'), hasLength(1));

      final lockBtn = find.byKey(const ValueKey('homeActionLock-child-1'));
      await tester.scrollUntilVisible(
        lockBtn,
        120,
        scrollable: homeVerticalScrollable(),
      );
      await tester.pumpAndSettle();
      await tester.tap(lockBtn);
      await flushHttp(tester);
      await tester.pump();
      final lockCalls = api.calls('POST', '/v1/devices/dev-1/command');
      expect(lockCalls, hasLength(1));
      expect(lockCalls.first.body['command'], 'lock');

      await tester.tap(find.text('Undo').last);
      await flushHttp(tester);
      await tester.pumpAndSettle();
      final allCalls = api.calls('POST', '/v1/devices/dev-1/command');
      expect(allCalls, hasLength(2));
      expect(allCalls.last.body['command'], 'unlock');
    });

    /// Mutant: enable bonus/pause/lock POSTs for an iPhone-only child and unsupported
    /// API calls are sent instead of showing `Not yet available on iPhone`.
    testWidgets('G6: iPhone-only child shows Not yet available on iPhone and sends 0 unsupported commands', (tester) async {
      final api = FakeApiClient({
        ...p07Routes(
          familyMe: {
            ...familyMeTwoChildren(),
            'children': [
              {
                'id': 'child-ios',
                'familyId': 'fam-1',
                'displayName': 'Maya',
                'birthYear': 2014,
                'screenTimeTodayMinutes': 0,
              },
            ],
            'devices': [
              {
                'id': 'dev-ios',
                'childId': 'child-ios',
                'platform': 'ios',
                'model': 'iPhone 14',
                'osVersion': '17.4',
                'status': 'online',
                'batteryPct': 88,
                'lastSeen': weekdayNow.toIso8601String(),
              },
            ],
          },
        ),
        'GET /v1/rules/child-ios': (_) => ruleSetPayload('child-ios'),
        'GET /v1/controls/children/child-ios/status': (_) => {'paused': false},
        'GET /v1/devices/dev-ios/commands/history': (_) => {'items': <dynamic>[]},
        'GET /v1/location/child-ios/latest': (_) => {'latest': null},
      });

      await tester.pumpWidget(buildP07App(api: api));
      await flushHttp(tester);
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('homeIosTimeNotYet-child-ios')), findsOneWidget);
      expect(find.byKey(const ValueKey('homeIosControlsNotYet-child-ios')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('homeActionPauseInternet-child-ios')));
      await tester.pump();
      expect(api.calls('POST', '/v1/controls/children/child-ios/pause'), isEmpty);
    });
  });

  group('P-07 + P-07-RTL layout & Arabic Bureau compliance matrix', () {
    for (final locale in const [Locale('en'), Locale('ar')]) {
      for (final mode in const [ThemeMode.light, ThemeMode.dark]) {
        for (final (size, scale) in const [
          (Size(390, 844), 1.0),
          (Size(320, 568), 2.0),
        ]) {
          final label =
              '${locale.languageCode} | ${mode.name} | ${size.width.toInt()}x${size.height.toInt()} | ${scale}x';

          /// Mutant: use fixed 1-row action buttons or omit RTL/Western digits
          /// and 320px at 2.0x overflows or fails Arabic Bureau checks.
          testWidgets('renders cleanly without overflow or ArabicIndic digits [$label]', (tester) async {
            tester.view.physicalSize = size;
            tester.view.devicePixelRatio = 1.0;
            addTearDown(() {
              tester.view.resetPhysicalSize();
              tester.view.resetDevicePixelRatio();
            });

            final baseFamily = familyMeTwoChildren(
              alexName: locale.languageCode == 'ar' ? 'محمد مصطفى' : 'Alex',
            );
            final children = [
              (baseFamily['children'] as List).first,
              {
                'id': 'child-2',
                'familyId': 'fam-1',
                'displayName': locale.languageCode == 'ar' ? 'سارة' : 'Sam',
                'birthYear': 2016,
                'screenTimeTodayMinutes': 10,
              },
            ];

            final api = FakeApiClient({
              ...p07Routes(
                familyMe: {
                  ...baseFamily,
                  'children': children,
                },
                alerts: [
                  {
                    'id': 'req-frame-1',
                    'childId': 'child-1',
                    'deviceId': 'dev-1',
                    'severity': 'info',
                    'category': 'app_blocked',
                    'title': 'Time request',
                    'body': 'Body',
                    'metadata': {
                      'requestType': 'time',
                      'reason': 'daily_limit',
                      'minutes': '15',
                    },
                    'createdAt': weekdayNow
                        .subtract(const Duration(minutes: 4))
                        .toIso8601String(),
                    'acknowledged': false,
                  },
                  {
                    'id': 'urgent-frame-1',
                    'childId': 'child-2',
                    'severity': 'critical',
                    'category': 'sos',
                    'title': 'SOS pressed',
                    'body': 'SOS body',
                    'createdAt': weekdayNow
                        .subtract(const Duration(minutes: 8))
                        .toIso8601String(),
                    'acknowledged': false,
                  },
                ],
              ),
              'GET /v1/location/child-1/latest': (_) => {
                    'latest': {
                      'lat': 25.1124,
                      'lng': 55.1980,
                      'accuracyMeters': 18.0,
                      'timestamp': weekdayNow.subtract(const Duration(minutes: 4)).toIso8601String(),
                      'recordedAt': weekdayNow
                          .subtract(const Duration(minutes: 4))
                          .toIso8601String(),
                    },
                  },
            });

            await tester.pumpWidget(
              buildP07App(
                api: api,
                locale: locale,
                themeMode: mode,
                size: size,
                textScale: scale,
              ),
            );
            await flushHttp(tester);
            await tester.pumpAndSettle();

            final exceptions = drainExceptions(tester);
            expect(exceptions, isEmpty, reason: 'Overflow in $label: $exceptions');

            final framesDir = Platform.environment['OSRA_P07_FRAMES_DIR'];
            if (framesDir != null && framesDir.isNotEmpty) {
              final boundary = tester.renderObject<RenderRepaintBoundary>(
                find.byKey(frameBoundaryKey),
              );
              await tester.runAsync(() async {
                final image = await boundary.toImage(pixelRatio: 2.0);
                final byteData =
                    await image.toByteData(format: ui.ImageByteFormat.png);
                image.dispose();
                if (byteData != null) {
                  final outDir = Directory(framesDir);
                  if (!outDir.existsSync()) outDir.createSync(recursive: true);
                  final scalePct = (scale * 100).round();
                  final name =
                      'p07_home_${locale.languageCode}_${mode.name}_${size.width.toInt()}_$scalePct.png';
                  File('${outDir.path}/$name')
                      .writeAsBytesSync(byteData.buffer.asUint8List());
                }
              });
            }

            if (locale.languageCode == 'ar') {
              final ctx = tester.element(find.byType(HomeP07Screen));
              expect(Directionality.of(ctx), TextDirection.rtl);
              final lockAction = find.byKey(const ValueKey('homeActionLock-child-1'));
              await tester.scrollUntilVisible(
                lockAction,
                120,
                scrollable: homeVerticalScrollable(),
              );
              await tester.pumpAndSettle();
              expect(find.text('قفل كل الأجهزة'), findsWidgets);
              expect(find.text('إيقاف الإنترنت مؤقتًا'), findsWidgets);
              for (final t in tester.widgetList<Text>(find.byType(Text))) {
                final s = t.data ?? '';
                expect(
                  RegExp(r'[\u0660-\u0669\u06F0-\u06F9]').hasMatch(s),
                  isFalse,
                  reason: 'Arabic-Indic digit found in "$s"',
                );
              }
            }

            if (size.width == 320 && scale == 2.0) {
              final b1 = find.byKey(const ValueKey('homeActionPlus15-child-1'));
              final b2 = find.byKey(const ValueKey('homeActionPlus30-child-1'));
              await tester.scrollUntilVisible(
                b2,
                120,
                scrollable: homeVerticalScrollable(),
              );
              await tester.pumpAndSettle();
              expect(
                tester.getRect(b2).top,
                greaterThanOrEqualTo(tester.getRect(b1).bottom - 0.5),
              );
              expect(drainExceptions(tester), isEmpty);
              // U86 (#650): at 320px and 200% text, the bottom bar stays one row
              // (all four tabs share the same top Y and total bar height <= 80).
              // Mutant: restoring `twoRows = scale > 1.35 || width < 340` puts
              // `p07Tab-family` on a second row and fails these assertions.
              final homeRect = tester.getRect(find.byKey(const ValueKey('p07Tab-home')));
              for (final tabKey in const [
                ValueKey('p07Tab-alerts'),
                ValueKey('p07Tab-family'),
                ValueKey('p07Tab-settings'),
              ]) {
                final r = tester.getRect(find.byKey(tabKey));
                expect((r.top - homeRect.top).abs(), lessThanOrEqualTo(1.0));
              }
              expect(
                tester.getRect(find.byKey(const ValueKey('p07BottomNav'))).height,
                lessThanOrEqualTo(80.0),
              );
              if (framesDir != null && framesDir.isNotEmpty) {
                final boundary = tester.renderObject<RenderRepaintBoundary>(
                  find.byKey(frameBoundaryKey),
                );
                await tester.runAsync(() async {
                  final image = await boundary.toImage(pixelRatio: 2.0);
                  final byteData =
                      await image.toByteData(format: ui.ImageByteFormat.png);
                  image.dispose();
                  if (byteData != null) {
                    final name =
                        'p07_home_${locale.languageCode}_${mode.name}_320_200_actions.png';
                    File('$framesDir/$name')
                        .writeAsBytesSync(byteData.buffer.asUint8List());
                  }
                });
              }
            }
          });
        }
      }
    }
  });
}