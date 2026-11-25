import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:familyshield_parent/api/models.dart';
import 'package:familyshield_parent/core/date_formatting.dart';
import 'package:familyshield_parent/features/alerts/alert_detail_screen.dart';
import 'package:familyshield_parent/features/alerts/alerts_screen.dart';
import 'package:familyshield_parent/l10n/l10n.dart';
import 'package:familyshield_parent/providers/auth_provider.dart';
import 'package:familyshield_parent/providers/onboarding_provider.dart';
import 'package:familyshield_parent/push/notification_tap.dart';
import 'package:familyshield_parent/theme/app_theme.dart';

import 'fake_api_client.dart';
import 'frame_capture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final fixedNow = DateTime(2026, 11, 21, 10, 0);
  final alertTime = DateTime(2026, 11, 21, 9, 5);

  setUpAll(() async {
    await configureDateFormatting();
    await loadFrameFonts();
  });

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    notificationTapController.clear();
  });

  Alert sampleSocialAlert({
    String id = 'alert-social-1',
    String category = 'social_concern',
    String app = 'whatsapp',
    List<String> concernTypes = const ['cyberbullying'],
    String? sourceEventId,
  }) =>
      Alert(
        id: id,
        childId: 'child-1',
        deviceId: 'dev-1',
        category: category,
        severity: 'warning',
        title: '$app concern (warning)',
        body: 'Flagged message (${concernTypes.join(', ')})',
        metadata: {
          'app': app,
          'contact': 'Test Group',
          'concernTypes': concernTypes,
          if (sourceEventId != null) 'latestSourceEventId': sourceEventId,
        },
        createdAt: alertTime,
      );

  FakeApiClient apiWith({
    List<Map<String, dynamic>>? alerts,
    Object? socialEvents,
  }) =>
      FakeApiClient({
        ...standardRoutes(),
        'GET /v1/alerts': (_) => {
              'items': alerts ??
                  [
                    {
                      'id': 'alert-social-1',
                      'childId': 'child-1',
                      'deviceId': 'dev-1',
                      'category': 'social_concern',
                      'severity': 'warning',
                      'title': 'whatsapp concern (warning)',
                      'body': 'Flagged message (cyberbullying)',
                      'metadata': {
                        'app': 'whatsapp',
                        'contact': 'Test Group',
                        'concernTypes': ['cyberbullying'],
                      },
                      'createdAt': alertTime.toUtc().toIso8601String(),
                    },
                  ],
              'meta': {'total': 1, 'page': 1, 'limit': 20},
            },
        'GET /v1/social/events': (_) {
          if (socialEvents is DioException) throw socialEvents;
          return {
            'items': socialEvents ??
                [
                  {
                    'id': 'evt-1',
                    'childId': 'child-1',
                    'app': 'whatsapp',
                    'contact': 'Test Group',
                    'severity': 'warning',
                    'concernTypes': ['cyberbullying'],
                    'preview':
                        'Synthetic vault excerpt only shown in Social activity',
                    'createdAt': alertTime.toUtc().toIso8601String(),
                  },
                ],
          };
        },
      });

  Future<void> pumpDetail(
    WidgetTester tester, {
    required FakeApiClient api,
    String alertId = 'alert-social-1',
    Alert? initialAlert,
    String lang = 'en',
    bool dark = false,
    double textScale = 1.0,
    double width = 390,
    bool frameBoundary = false,
    List<String>? navigatedTo,
  }) async {
    tester.view.physicalSize = Size(width, 844);
    tester.view.devicePixelRatio = 1.0;
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      tester.platformDispatcher.clearTextScaleFactorTestValue();
    });

    final router = GoRouter(
      initialLocation: '/alerts/$alertId',
      routes: [
        GoRoute(
          path: '/alerts',
          builder: (_, __) {
            navigatedTo?.add('/alerts');
            return const Scaffold(body: Text('ALL_ALERTS_LIST'));
          },
        ),
        GoRoute(
          path: '/alerts/:id',
          builder: (_, s) => AlertDetailScreen(
            alertId: s.pathParameters['id']!,
            initialAlert: initialAlert,
            nowProvider: () => fixedNow,
          ),
        ),
        GoRoute(
          path: '/child/:id/social',
          builder: (_, s) {
            final path = '/child/${s.pathParameters['id']}/social';
            navigatedTo?.add(path);
            return Scaffold(
                body: Text('SOCIAL_SCREEN:${s.pathParameters['id']}'));
          },
        ),
      ],
    );

    await tester.pumpWidget(ProviderScope(
      overrides: [apiClientProvider.overrideWithValue(api)],
      child: MaterialApp.router(
        routerConfig: router,
        locale: Locale(lang),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: withFrameFonts(AppTheme.light),
        darkTheme: withFrameFonts(AppTheme.dark),
        themeMode: dark ? ThemeMode.dark : ThemeMode.light,
        builder: frameBoundary
            ? (context, child) => RepaintBoundary(
                  key: const ValueKey('frameRoot'),
                  child: child!,
                )
            : null,
      ),
    ));
    await tester.pumpAndSettle();
  }

  group('AlertDetailScreen (#972)', () {
    test(
        'message vote eligibility is limited to AI message categories with a source id',
        () {
      Alert alertFor(String category, {String? sourceId}) => Alert(
            id: 'alert-1',
            childId: 'child-1',
            category: category,
            severity: 'warning',
            title: 'Alert',
            body: '',
            metadata: {
              if (sourceId != null) 'latestSourceEventId': sourceId,
            },
            createdAt: alertTime,
          );

      for (final category in const [
        'social_concern',
        'gaming_chat',
        'ai_concern',
        'cyberbullying',
        'self_harm',
        'grooming',
      ]) {
        expect(
            socialVoteEventId(alertFor(category, sourceId: 'evt-1')), 'evt-1');
      }
      for (final category in const ['sos', 'geofence', 'app_blocked']) {
        expect(
            socialVoteEventId(alertFor(category, sourceId: 'evt-1')), isNull);
      }
      expect(socialVoteEventId(alertFor('self_harm')), isNull);
      expect(socialVoteEventId(alertFor('self_harm', sourceId: ' ')), isNull);
    });

    testWidgets(
        'shows localized hierarchy, never leaks vault excerpt, and opens Social activity',
        (tester) async {
      final visited = <String>[];
      await pumpDetail(
        tester,
        api: apiWith(),
        initialAlert: sampleSocialAlert(),
        navigatedTo: visited,
      );

      expect(find.text('Social safety alert'), findsOneWidget);
      expect(find.byKey(const ValueKey('alertDetailAppChip')), findsOneWidget);
      expect(find.text('Cyberbullying'), findsOneWidget);
      expect(
          find.byKey(const ValueKey('alertDetailChildDevice')), findsOneWidget);
      expect(find.textContaining('Alex'), findsOneWidget);
      expect(find.textContaining('Pixel 7a'), findsOneWidget);
      expect(find.textContaining('09:05'), findsOneWidget);
      expect(find.textContaining('Flagged for review in'), findsOneWidget);
      // Security invariant: vault excerpt must NEVER appear on the alert detail screen.
      expect(find.textContaining('Synthetic vault excerpt'), findsNothing);
      // Raw English server body must not leak.
      expect(find.textContaining('Flagged message'), findsNothing);
      // Conversation guide is present.
      expect(find.text('How to talk about this'), findsOneWidget);

      // Tapping Open Social activity reaches the existing authorized Social surface.
      await tester.tap(find.byKey(const ValueKey('alertDetailOpenSocial')));
      await tester.pumpAndSettle();
      expect(visited, contains('/child/child-1/social'));
      expect(find.text('SOCIAL_SCREEN:child-1'), findsOneWidget);
    });

    testWidgets(
        'latestSourceEventId wires the social detail vote to that event',
        (tester) async {
      // Mutant: voting by alert id, or hiding controls when this metadata is
      // present, either 404s or leaves an AI-flagged message without feedback.
      final api = FakeApiClient({
        ...standardRoutes(),
        'GET /v1/social/events': (_) => {
              'items': [
                {
                  'id': 'evt-1',
                  'childId': 'child-1',
                  'app': 'whatsapp',
                  'contact': 'Test Group',
                  'severity': 'warning',
                  'concernTypes': ['cyberbullying'],
                  'preview': 'Synthetic vault excerpt',
                  'createdAt': alertTime.toUtc().toIso8601String(),
                },
              ],
            },
        'POST /v1/social/events/evt-1/feedback': (request) => {
              'feedback': {
                'verdict': request.body['verdict'],
                'parentDisplayName': 'QA Parent',
                'firstVotedAt': '2026-11-24T10:01:00.000Z',
                'lastChangedAt': '2026-11-24T10:01:00.000Z',
              },
            },
        'DELETE /v1/social/events/evt-1/feedback': (_) => {'feedback': null},
      });
      await pumpDetail(
        tester,
        api: api,
        initialAlert: sampleSocialAlert(sourceEventId: 'evt-1'),
      );

      expect(find.text('Was OSRA right to flag this?'), findsOneWidget);
      await tester.tap(find.text('Concerning'));
      await tester.pumpAndSettle();
      expect(api.calls('POST', '/v1/social/events/evt-1/feedback').single.body,
          {'verdict': 'concerning'});
      expect(api.calls('POST', '/v1/social/events/alert-social-1/feedback'),
          isEmpty);
      await tester.pump(const Duration(seconds: 5));
    });

    for (final category in const ['self_harm', 'grooming']) {
      testWidgets(
          '$category detail offers the same source-event vote without extra warnings',
          (tester) async {
        // Mutant: limiting controls to social_concern/gaming_chat leaves these
        // AI-flagged message categories out, contrary to the Bureau design.
        await pumpDetail(
          tester,
          api: apiWith(),
          initialAlert: Alert(
            id: 'alert-$category-1',
            childId: 'child-1',
            category: category,
            severity: 'critical',
            title: 'AI concern',
            body: '',
            metadata: const {'latestSourceEventId': 'evt-1'},
            createdAt: alertTime,
          ),
        );

        expect(find.byKey(const ValueKey('alertDetailGeneralScroll')),
            findsOneWidget);
        expect(find.text('Was OSRA right to flag this?'), findsOneWidget);
        expect(find.text('Not concerning'), findsOneWidget);
      });
    }

    testWidgets('general AI detail hides votes when its source preview expired',
        (tester) async {
      await pumpDetail(
        tester,
        api: apiWith(socialEvents: const <Map<String, dynamic>>[]),
        initialAlert: Alert(
          id: 'alert-self-harm-expired',
          childId: 'child-1',
          category: 'self_harm',
          severity: 'critical',
          title: 'AI concern',
          body: '',
          metadata: const {'latestSourceEventId': 'evt-1'},
          createdAt: alertTime,
        ),
      );

      expect(find.byKey(const ValueKey('alertDetailGeneralScroll')),
          findsOneWidget);
      expect(find.text('Was OSRA right to flag this?'), findsNothing);
    });

    testWidgets(
        'a social alert without latestSourceEventId does not offer a vote',
        (tester) async {
      await pumpDetail(tester,
          api: apiWith(), initialAlert: sampleSocialAlert());

      expect(find.text('Was OSRA right to flag this?'), findsNothing);
    });

    testWidgets('shows gaming chat title for gaming_chat alerts',
        (tester) async {
      await pumpDetail(
        tester,
        api: apiWith(socialEvents: [
          {
            'id': 'evt-2',
            'childId': 'child-1',
            'app': 'discord',
            'contact': 'Squad',
            'severity': 'warning',
            'concernTypes': ['grooming'],
            'preview': 'Hidden excerpt',
            'createdAt': alertTime.toUtc().toIso8601String(),
          },
        ]),
        initialAlert: sampleSocialAlert(
          category: 'gaming_chat',
          app: 'discord',
          concernTypes: const ['grooming'],
        ),
      );

      expect(find.text('Gaming chat alert'), findsOneWidget);
      expect(find.byKey(const ValueKey('alertDetailConcern-grooming')),
          findsOneWidget);
      expect(find.textContaining('Hidden excerpt'), findsNothing);
    });

    testWidgets(
        'missing social permission shows unavailable-for-account state and hides CTA',
        (tester) async {
      // Mutant: dropping the 403 permission_required branch in resolveSocialPreviewAvailability
      // would show expired or the Open Social activity CTA instead of the permission message.
      final forbidden = DioException(
        requestOptions: RequestOptions(path: '/v1/social/events'),
        response: Response(
          requestOptions: RequestOptions(path: '/v1/social/events'),
          statusCode: 403,
          data: {'error': 'permission_required', 'permission': 'social'},
        ),
        type: DioExceptionType.badResponse,
      );
      await pumpDetail(
        tester,
        api: apiWith(socialEvents: forbidden),
        initialAlert: sampleSocialAlert(sourceEventId: 'evt-1'),
      );

      expect(find.byKey(const ValueKey('alertDetailPreviewNoPerm')),
          findsOneWidget);
      expect(find.text('Preview unavailable for your account'), findsOneWidget);
      expect(find.byKey(const ValueKey('alertDetailOpenSocial')), findsNothing);
      expect(find.text('Was OSRA right to flag this?'), findsNothing);
      expect(find.text('How to talk about this'), findsOneWidget);
    });

    testWidgets(
        'empty vault shows preview-no-longer-available state and keeps guide usable',
        (tester) async {
      await pumpDetail(
        tester,
        api: apiWith(socialEvents: const <Map<String, dynamic>>[]),
        initialAlert: sampleSocialAlert(sourceEventId: 'evt-1'),
      );

      expect(find.byKey(const ValueKey('alertDetailPreviewExpired')),
          findsOneWidget);
      expect(find.text('Preview no longer available'), findsOneWidget);
      expect(find.byKey(const ValueKey('alertDetailOpenSocial')), findsNothing);
      expect(find.text('Was OSRA right to flag this?'), findsNothing);
      expect(find.text('How to talk about this'), findsOneWidget);
    });

    testWidgets('unavailable alert id keeps /alerts reachable', (tester) async {
      final visited = <String>[];
      await pumpDetail(
        tester,
        api: apiWith(alerts: const []),
        alertId: 'missing-id',
        navigatedTo: visited,
      );

      expect(
          find.byKey(const ValueKey('alertDetailUnavailable')), findsOneWidget);
      expect(find.text('Alert unavailable'), findsOneWidget);
      await tester.tap(find.text('All alerts'));
      await tester.pumpAndSettle();
      expect(visited, contains('/alerts'));
    });

    testWidgets(
        '200% text scale scrolls cleanly to primary CTA in EN/AR light and dark',
        (tester) async {
      for (final lang in const ['en', 'ar']) {
        for (final dark in const [false, true]) {
          await pumpDetail(
            tester,
            api: apiWith(),
            initialAlert: sampleSocialAlert(),
            lang: lang,
            dark: dark,
            textScale: 2.0,
          );
          final cta = find.byKey(const ValueKey('alertDetailOpenSocial'));
          await tester.scrollUntilVisible(
            cta,
            150,
            scrollable: find.byType(Scrollable).first,
          );
          await tester.pumpAndSettle();
          expect(cta, findsOneWidget);
          expect(tester.takeException(), isNull);
        }
      }
    });

    testWidgets(
        'tapping a social_concern row on AlertsScreen opens full-screen AlertDetailScreen',
        (tester) async {
      tester.view.physicalSize = const Size(400, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      await tester.pumpWidget(ProviderScope(
        overrides: [apiClientProvider.overrideWithValue(apiWith())],
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: AppTheme.light,
          home: AlertsScreen(nowProvider: () => fixedNow),
        ),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Social safety alert').first);
      await tester.pumpAndSettle();

      expect(find.byType(AlertDetailScreen), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
    });

    testWidgets(
        'Finding 1: regular app_blocked alert entered via notification tap renders general presentation without Social CTA',
        (tester) async {
      // Mutant: removing `if (!isSocialAlertCategory(alert.category))` renders
      // _SocialAlertDetailBody with Open Social activity and queries /v1/social/events.
      var socialEventsCalls = 0;
      final api = FakeApiClient({
        ...standardRoutes(),
        'GET /v1/alerts': (_) => {
              'items': [
                {
                  'id': 'alert-blocked-1',
                  'childId': 'child-1',
                  'deviceId': 'dev-1',
                  'category': 'app_blocked',
                  'severity': 'info',
                  'title': 'Blocked app attempt',
                  'body': 'TikTok was blocked by your schedule.',
                  'metadata': {'app': 'tiktok'},
                  'createdAt': alertTime.toUtc().toIso8601String(),
                },
              ],
              'meta': {'total': 1, 'page': 1, 'limit': 50},
            },
        'GET /v1/social/events': (_) {
          socialEventsCalls++;
          return {'items': []};
        },
      });

      await pumpDetail(tester, api: api, alertId: 'alert-blocked-1');
      expect(find.byKey(const ValueKey('alertDetailGeneralScroll')),
          findsOneWidget);
      expect(find.byKey(const ValueKey('alertDetailBody')), findsOneWidget);
      expect(find.text('TikTok was blocked by your schedule.'), findsNothing);
      expect(
        find.text(
            '\u{2068}Alex\u{2069} tried to open it. Nothing for you to do.'),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('alertDetailOpenSocial')), findsNothing);
      expect(find.byKey(const ValueKey('alertDetailFraming')), findsNothing);
      expect(socialEventsCalls, 0);
    });

    testWidgets(
        'Finding 2: connection timeout on Social preview shows inline retry while keeping alert summary visible, and recovers on tap',
        (tester) async {
      // Mutant: returning SocialPreviewAvailability.expired on non-permission errors
      // shows alertDetailPreviewExpired instead of alertDetailPreviewRetry.
      var attempt = 0;
      final api = FakeApiClient({
        ...standardRoutes(),
        'GET /v1/alerts': (_) => {
              'items': [
                {
                  'id': 'alert-social-1',
                  'childId': 'child-1',
                  'deviceId': 'dev-1',
                  'category': 'social_concern',
                  'severity': 'warning',
                  'title': 'whatsapp concern (warning)',
                  'body': 'Flagged message (cyberbullying)',
                  'metadata': {
                    'app': 'whatsapp',
                    'contact': 'Test Group',
                    'concernTypes': ['cyberbullying'],
                  },
                  'createdAt': alertTime.toUtc().toIso8601String(),
                },
              ],
              'meta': {'total': 1, 'page': 1, 'limit': 50},
            },
        'GET /v1/social/events': (_) {
          attempt++;
          if (attempt == 1) {
            throw DioException(
              requestOptions: RequestOptions(path: '/v1/social/events'),
              type: DioExceptionType.connectionTimeout,
            );
          }
          return {
            'items': [
              {
                'id': 'evt-1',
                'childId': 'child-1',
                'app': 'whatsapp',
                'contact': 'Test Group',
                'severity': 'warning',
                'concernTypes': ['cyberbullying'],
                'preview':
                    'Synthetic vault excerpt only shown in Social activity',
                'createdAt': alertTime.toUtc().toIso8601String(),
              },
            ],
          };
        },
      });

      await pumpDetail(tester, api: api, alertId: 'alert-social-1');
      // Alert summary stays visible; expiry copy must NOT appear on timeout.
      expect(find.byKey(const ValueKey('alertDetailTitle')), findsOneWidget);
      expect(find.byKey(const ValueKey('alertDetailAppChip')), findsOneWidget);
      expect(find.byKey(const ValueKey('alertDetailFraming')), findsOneWidget);
      expect(find.byKey(const ValueKey('alertDetailPreviewExpired')),
          findsNothing);
      expect(find.byKey(const ValueKey('alertDetailPreviewRetry')),
          findsOneWidget);

      await tester
          .tap(find.byKey(const ValueKey('alertDetailPreviewRetryButton')));
      await tester.pumpAndSettle();

      expect(attempt, 2);
      expect(
          find.byKey(const ValueKey('alertDetailPreviewRetry')), findsNothing);
      expect(
          find.byKey(const ValueKey('alertDetailOpenSocial')), findsOneWidget);
    });

    testWidgets(
        'Finding 3: older alert outside page 1 of 50 entered via notification tap paginates and renders readable detail',
        (tester) async {
      // Mutant: searching only page 1 of alertsProvider renders alertDetailUnavailable
      // for alert-older-62 on page 2.
      final requestedPages = <int>[];
      final page1Items = List.generate(
        50,
        (i) => {
          'id': 'alert-recent-$i',
          'childId': 'child-1',
          'deviceId': 'dev-1',
          'category': 'app_blocked',
          'severity': 'info',
          'title': 'Recent alert $i',
          'body': 'Recent body $i',
          'metadata': const <String, dynamic>{},
          'createdAt': alertTime.toUtc().toIso8601String(),
        },
      );
      final page2Items = [
        {
          'id': 'alert-older-62',
          'childId': 'child-1',
          'deviceId': 'dev-1',
          'category': 'social_concern',
          'severity': 'warning',
          'title': 'whatsapp concern (warning)',
          'body': 'Flagged message (cyberbullying)',
          'metadata': {
            'app': 'whatsapp',
            'contact': 'Older Group',
            'concernTypes': ['cyberbullying'],
          },
          'createdAt': alertTime.toUtc().toIso8601String(),
        },
      ];

      final api = FakeApiClient({
        ...standardRoutes(),
        'GET /v1/alerts': (opts) {
          final page = (opts.query['page'] as int?) ?? 1;
          requestedPages.add(page);
          return {
            'items': page == 1 ? page1Items : page2Items,
            'meta': {'total': 51, 'page': page, 'limit': 50},
          };
        },
        'GET /v1/social/events': (_) => {
              'items': [
                {
                  'id': 'evt-older',
                  'childId': 'child-1',
                  'app': 'whatsapp',
                  'contact': 'Older Group',
                  'severity': 'warning',
                  'concernTypes': ['cyberbullying'],
                  'preview': 'Synthetic older vault excerpt',
                  'createdAt': alertTime.toUtc().toIso8601String(),
                },
              ],
            },
      });

      await pumpDetail(tester, api: api, alertId: 'alert-older-62');
      expect(requestedPages, [1, 2]);
      expect(
          find.byKey(const ValueKey('alertDetailUnavailable')), findsNothing);
      expect(find.byKey(const ValueKey('alertDetailScroll')), findsOneWidget);
      expect(
          find.byKey(const ValueKey('alertDetailOpenSocial')), findsOneWidget);
    });

    testWidgets(
        'Finding 4 (7063101979 #1): SOS with event location entered via notification tap renders SOS location panel and actions without raw English body',
        (tester) async {
      // Mutant: omitting the SOS location panel / sosAlertActions or rendering alert.body
      // for sos fails the assertions below.
      final api = FakeApiClient({
        ...standardRoutes(),
        'GET /v1/alerts': (_) => {
              'items': [
                {
                  'id': 'alert-sos-1',
                  'childId': 'child-1',
                  'deviceId': 'dev-1',
                  'category': 'sos',
                  'severity': 'critical',
                  'title': 'SOS',
                  'body': 'Raw English SOS body from agent',
                  'metadata': {
                    'lat': 25.2048,
                    'lng': 55.2708,
                    'accuracyM': 12.0,
                    'capturedAt': alertTime.toUtc().toIso8601String(),
                    'latestSourceEventId': 'evt-1',
                  },
                  'createdAt': alertTime.toUtc().toIso8601String(),
                },
              ],
              'meta': {'total': 1, 'page': 1, 'limit': 50},
            },
      });

      await pumpDetail(tester, api: api, alertId: 'alert-sos-1', lang: 'ar');
      expect(find.byKey(const ValueKey('alertDetailGeneralScroll')),
          findsOneWidget);
      expect(find.byKey(const ValueKey('alert-sos-location')), findsOneWidget);
      expect(find.byKey(const ValueKey('alert-sos-location-line')),
          findsOneWidget);
      expect(find.textContaining('Raw English SOS body'), findsNothing);
      expect(find.byKey(const ValueKey('alertDetailOpenSocial')), findsNothing);
      expect(find.text('Was OSRA right to flag this?'), findsNothing);
    });

    testWidgets(
        'location alerts never offer message votes even with source metadata',
        (tester) async {
      await pumpDetail(
        tester,
        api: FakeApiClient(standardRoutes()),
        initialAlert: Alert(
          id: 'alert-geofence-1',
          childId: 'child-1',
          category: 'geofence',
          severity: 'info',
          title: 'Location update',
          body: 'Arrived at school',
          metadata: const {'latestSourceEventId': 'evt-1'},
          createdAt: alertTime,
        ),
      );

      expect(find.byKey(const ValueKey('alertDetailGeneralScroll')),
          findsOneWidget);
      expect(find.text('Was OSRA right to flag this?'), findsNothing);
    });

    testWidgets(
        'Finding 5 (7063101979 #2): unkeyed device_restarted in Arabic suppresses raw English body on notification entry',
        (tester) async {
      // Mutant: rendering alert.body directly in _GeneralAlertDetailBody leaks raw English in Arabic.
      final api = FakeApiClient({
        ...standardRoutes(),
        'GET /v1/alerts': (_) => {
              'items': [
                {
                  'id': 'alert-restart-1',
                  'childId': 'child-1',
                  'deviceId': 'dev-1',
                  'category': 'device_restarted',
                  'severity': 'warning',
                  'title': 'Device restarted',
                  'body': 'Pixel 7 restarted and came back online.',
                  'metadata': const <String, dynamic>{},
                  'createdAt': alertTime.toUtc().toIso8601String(),
                },
              ],
              'meta': {'total': 1, 'page': 1, 'limit': 50},
            },
      });

      await pumpDetail(tester,
          api: api, alertId: 'alert-restart-1', lang: 'ar');
      expect(find.byKey(const ValueKey('alertDetailGeneralScroll')),
          findsOneWidget);
      expect(find.byKey(const ValueKey('alertDetailBody')), findsNothing);
      expect(find.textContaining('Pixel 7 restarted'), findsNothing);
    });

    testWidgets(
        'Finding 6 (7063101979 #3): bounded scan hitting maxPages with more server pages renders incomplete-lookup state rather than Alert unavailable',
        (tester) async {
      // Mutant: returning AlertLookupResult.notFound() when seen < total after maxPages
      // renders alertDetailUnavailable instead of alertDetailLookupIncomplete.
      var pagesRequested = 0;
      final api = FakeApiClient({
        ...standardRoutes(),
        'GET /v1/alerts': (opts) {
          pagesRequested++;
          final page = (opts.query['page'] as int?) ?? 1;
          return {
            'items': List.generate(
              50,
              (i) => {
                'id': 'alert-p$page-$i',
                'childId': 'child-1',
                'deviceId': 'dev-1',
                'category': 'app_blocked',
                'severity': 'info',
                'title': 'Alert $page-$i',
                'body': 'Body',
                'metadata': const <String, dynamic>{},
                'createdAt': alertTime.toUtc().toIso8601String(),
              },
            ),
            'meta': {'total': 1500, 'page': page, 'limit': 50},
          };
        },
      });

      await pumpDetail(tester, api: api, alertId: 'alert-very-old-1499');
      expect(pagesRequested, 20);
      expect(find.byKey(const ValueKey('alertDetailLookupIncomplete')),
          findsOneWidget);
      expect(
          find.byKey(const ValueKey('alertDetailUnavailable')), findsNothing);
    });
  });

  group('Bureau vote frames (writes only with OSRA_FRAME_DIR)', () {
    Map<String, dynamic> feedback(String verdict, String name) => {
          'verdict': verdict,
          'parentDisplayName': name,
          'firstVotedAt': '2026-11-24T10:01:00.000Z',
          'lastChangedAt': '2026-11-24T10:02:00.000Z',
        };

    Map<String, dynamic> frameEvent(String state) {
      final selected = state == 'concerning' || state == 'not_concerning';
      return {
        'id': 'evt-1',
        'childId': 'child-1',
        'app': 'whatsapp',
        'contact': 'Test Group',
        'severity': 'warning',
        'concernTypes': ['cyberbullying'],
        'preview': 'Synthetic vault excerpt only shown in Social activity',
        'createdAt': alertTime.toUtc().toIso8601String(),
        'latestFeedback': switch (state) {
          'unset' => null,
          'cleared' => feedback('concerning', 'Lina'),
          _ => feedback(state, 'QA Parent'),
        },
        'ownFeedback': selected ? feedback(state, 'QA Parent') : null,
      };
    }

    for (final lang in const ['en', 'ar']) {
      for (final narrow in [false, true]) {
        for (final dark in [false, true]) {
          testWidgets(
              'Alert detail $lang ${narrow ? '320-200' : '390'} ${dark ? 'dark' : 'light'}',
              (tester) async {
            for (final state in const [
              'unset',
              'concerning',
              'not_concerning',
              'cleared',
            ]) {
              await pumpDetail(
                tester,
                api: apiWith(socialEvents: [frameEvent(state)]),
                initialAlert: sampleSocialAlert(sourceEventId: 'evt-1'),
                lang: lang,
                dark: dark,
                width: narrow ? 320 : 390,
                textScale: narrow ? 2 : 1,
                frameBoundary: true,
              );
              final help = find.text(lang == 'ar'
                  ? 'إجابتك تساعد تطبيق أسرة للأطفال على فحص الرسائل بدقة أكبر.'
                  : 'Your answer helps OSRA check messages better.');
              await tester.scrollUntilVisible(
                help,
                150,
                scrollable: find.byType(Scrollable).first,
              );
              await tester.pumpAndSettle();
              expect(tester.takeException(), isNull);
              await maybeCaptureFrame(
                tester,
                'alert-detail-vote-$state-$lang-${dark ? 'dark' : 'light'}-${narrow ? '320-200' : '390'}.png',
              );
              await tester.pumpWidget(const SizedBox());
            }
          });
        }
      }
    }
  });

  group('NotificationTapController (#972 cold-start & warm-start auth gate)',
      () {
    test('preserves tapped alertId until authenticated, then consumes once',
        () {
      // Mutant: consuming pendingAlertId while authenticated == false drops a cold-start
      // notification tap across /login and fails the second assertion below.
      final ctrl = NotificationTapController();
      ctrl.recordTap('alert-social-1');
      expect(ctrl.pendingAlertId, 'alert-social-1');

      // Before sign-in: must NOT redirect or consume the queued id.
      expect(
        resolveNotificationAlertRedirect(
          authenticated: false,
          onboardingComplete: true,
          onboardingStep: OnboardingStep.none,
          controller: ctrl,
        ),
        isNull,
      );
      expect(ctrl.pendingAlertId, 'alert-social-1');

      // After sign-in: opens /alerts/:id and clears queue so Back does not loop.
      expect(
        resolveNotificationAlertRedirect(
          authenticated: true,
          onboardingComplete: true,
          onboardingStep: OnboardingStep.none,
          controller: ctrl,
        ),
        '/alerts/alert-social-1',
      );
      expect(ctrl.pendingAlertId, isNull);
    });

    test('rejects empty or route-injection payloads', () {
      final ctrl = NotificationTapController();
      ctrl.recordTap('');
      ctrl.recordTap('   ');
      ctrl.recordTap('bad/segment');
      ctrl.recordTap('id?x=1');
      ctrl.recordTap('id#frag');
      expect(ctrl.pendingAlertId, isNull);
    });
  });
}
