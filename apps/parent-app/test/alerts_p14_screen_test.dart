import 'package:dio/dio.dart';
import 'package:familyshield_parent/api/models.dart';
import 'package:familyshield_parent/app.dart' show appRoutes;
import 'package:familyshield_parent/features/alerts/alert_detail_screen.dart';
import 'package:familyshield_parent/features/alerts/alerts_p14_screen.dart';
import 'package:familyshield_parent/features/alerts/alerts_screen.dart';
import 'package:familyshield_parent/features/children/child_detail_screen.dart';
import 'package:familyshield_parent/l10n/app_localizations.dart';
import 'package:familyshield_parent/providers/auth_provider.dart';
import 'package:familyshield_parent/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'fake_api_client.dart';

Map<String, dynamic> _familyJson() => {
      'family': {'id': 'fam-1', 'name': 'Al-Mansoor'},
      'children': [
        {
          'id': 'child-1',
          'displayName': 'Layla',
          'devices': [],
        },
        {
          'id': 'child-2',
          'displayName': 'Omar',
          'devices': [],
        },
      ],
    };

Map<String, dynamic> _sampleAlert({
  required String id,
  String childId = 'child-1',
  String severity = 'info',
  String category = 'web_threat',
  String title = 'Blocked site attempted',
  String body = '',
  Map<String, dynamic> metadata = const {},
  String createdAt = '2026-11-27T08:00:00Z',
  String? updatedAt,
  bool acknowledged = false,
  int attemptCount = 1,
}) =>
    {
      'id': id,
      'childId': childId,
      'severity': severity,
      'category': category,
      'title': title,
      'body': body,
      'metadata': metadata,
      'createdAt': createdAt,
      if (updatedAt != null) 'updatedAt': updatedAt,
      'acknowledged': acknowledged,
      'attemptCount': attemptCount,
    };

Widget _p14RouterHarness({
  required FakeApiClient api,
  required bool p14Enabled,
  String initialLocation = '/alerts',
  Locale locale = const Locale('en'),
  ThemeMode themeMode = ThemeMode.light,
  double textScale = 1.0,
}) {
  final router = GoRouter(initialLocation: initialLocation, routes: appRoutes);
  return ProviderScope(
    key: UniqueKey(),
    overrides: [
      apiClientProvider.overrideWithValue(api),
      p14AlertsEnabledProvider.overrideWithValue(p14Enabled),
    ],
    child: MaterialApp.router(
      debugShowCheckedModeBanner: false,
      locale: locale,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: themeMode,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(textScale),
        ),
        child: child!,
      ),
      routerConfig: router,
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  // Mutant: counting plain `info` blocked-site alerts on the badge (or
  // omitting `info`-severity requests) fails the expected count of 3.
  test('computeP14BadgeCount counts unacked Urgent, Check soon, and Requests only (G9)', () {
    final alerts = [
      Alert.fromJson(_sampleAlert(id: 'u1', severity: 'critical', category: 'sos')),
      Alert.fromJson(_sampleAlert(id: 'w1', severity: 'warning', category: 'tamper')),
      Alert.fromJson(_sampleAlert(
        id: 'req1',
        severity: 'info',
        category: 'app_blocked',
        metadata: {'requestType': 'access', 'appName': 'Roblox'},
      )),
      // Plain info blocked attempt stays OFF the badge.
      Alert.fromJson(_sampleAlert(id: 'i1', severity: 'info', category: 'web_threat')),
      // Acknowledged critical alert stays OFF the badge.
      Alert.fromJson(_sampleAlert(
        id: 'u-ack',
        severity: 'critical',
        category: 'sos',
        acknowledged: true,
      )),
    ];

    expect(computeP14BadgeCount(alerts), 3);
    expect(p14LevelForSeverity('critical'), P14AlertLevel.urgent);
    expect(p14LevelForSeverity('warning'), P14AlertLevel.checkSoon);
    expect(p14LevelForSeverity('info'), P14AlertLevel.info);
  });

  // Mutant: sorting by `createdAt` instead of `effectiveTimestamp` (`latestAt`)
  // leaves the older-created grouped row below the newer-created row.
  test('sortP14Alerts orders grouped rows by latestAt descending (#1139/#1222)', () {
    final olderCreatedButUpdated = Alert.fromJson(_sampleAlert(
      id: 'grouped',
      createdAt: '2026-11-27T07:00:00Z',
      attemptCount: 3,
      metadata: {'latestAt': '2026-11-27T09:30:00Z'},
    ));
    final newerCreated = Alert.fromJson(_sampleAlert(
      id: 'single',
      createdAt: '2026-11-27T08:15:00Z',
    ));

    final sorted = sortP14Alerts([newerCreated, olderCreatedButUpdated]);
    expect(sorted.map((a) => a.id).toList(), ['grouped', 'single']);
  });

  // Mutant: rendering AlertsP14Screen when OSRA_UX_P14 is false (or leaving
  // Dismissible in P-14) fails the flag-off/flag-on assertions.
  testWidgets('OSRA_UX_P14 off renders legacy AlertsScreen; on renders AlertsP14Screen with no swipe-dismiss', (tester) async {
    final api = FakeApiClient({
      ...standardRoutes(),
      'GET /v1/family': (_) => _familyJson(),
      'GET /v1/alerts': (_) => {
            'items': [
              _sampleAlert(id: 'a1', severity: 'warning', category: 'tamper'),
            ],
            'total': 1,
            'page': 1,
            'limit': 20,
          },
    });

    await tester.pumpWidget(_p14RouterHarness(api: api, p14Enabled: false));
    await tester.pumpAndSettle();
    expect(find.byType(AlertsScreen), findsOneWidget);
    expect(find.byType(AlertsP14Screen), findsNothing);
    expect(find.byType(Dismissible), findsOneWidget);

    await tester.pumpWidget(_p14RouterHarness(api: api, p14Enabled: true));
    await tester.pumpAndSettle();
    expect(find.byType(AlertsP14Screen), findsOneWidget);
    expect(find.byType(Dismissible), findsNothing);
  });

  // Mutant: routing requests into Alerts (or ignoring child chips) fails the
  // segment and child-filter assertions.
  testWidgets('P-14 segments Alerts vs Requests, filters by child chip (A25), and shows grouped count + latest time', (tester) async {
    final api = FakeApiClient({
      ...standardRoutes(),
      'GET /v1/family': (_) => _familyJson(),
      'GET /v1/alerts': (_) => {
            'items': [
              _sampleAlert(
                id: 'a-urgent',
                childId: 'child-1',
                severity: 'critical',
                category: 'sos',
                createdAt: '2026-11-27T09:10:00Z',
              ),
              _sampleAlert(
                id: 'a-grouped',
                childId: 'child-2',
                severity: 'info',
                category: 'web_threat',
                attemptCount: 3,
                createdAt: '2026-11-27T07:00:00Z',
                metadata: {'latestAt': '2026-11-27T09:20:00Z'},
              ),
              _sampleAlert(
                id: 'r-access',
                childId: 'child-1',
                severity: 'info',
                category: 'app_blocked',
                createdAt: '2026-11-27T09:05:00Z',
                metadata: {
                  'requestType': 'access',
                  'packageId': 'com.roblox.client',
                  'appName': 'Roblox',
                },
              ),
            ],
            'total': 3,
            'page': 1,
            'limit': 20,
          },
    });

    await tester.pumpWidget(_p14RouterHarness(api: api, p14Enabled: true));
    await tester.pumpAndSettle();

    // Alerts segment shows urgent + grouped alert, NOT the access request.
    expect(find.byKey(const ValueKey('p14-row-a-urgent')), findsOneWidget);
    expect(find.byKey(const ValueKey('p14-row-a-grouped')), findsOneWidget);
    expect(find.byKey(const ValueKey('p14-row-r-access')), findsNothing);
    expect(find.text('Urgent'), findsOneWidget);
    expect(find.text('Info'), findsOneWidget);
    expect(find.textContaining('3 times'), findsOneWidget);

    // Filter to Layla (child-1): Omar's grouped alert disappears.
    await tester.tap(find.byKey(const ValueKey('p14-child-child-1')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('p14-row-a-urgent')), findsOneWidget);
    expect(find.byKey(const ValueKey('p14-row-a-grouped')), findsNothing);

    // Switch to Requests segment: Layla's access request appears.
    await tester.tap(find.byKey(const ValueKey('p14-seg-requests')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('p14-row-r-access')), findsOneWidget);
  });

  // Mutant: calling POST /v1/alerts/:id/ack on tap (or not pushing
  // AlertDetailScreen) fails the opening-does-not-review assertion.
  testWidgets('Tapping a P-14 alert opens AlertDetailScreen (P-15) without calling /ack', (tester) async {
    var ackCalls = 0;
    final api = FakeApiClient({
      ...standardRoutes(),
      'GET /v1/family': (_) => _familyJson(),
      'GET /v1/alerts': (_) => {
            'items': [
              _sampleAlert(
                id: 'a-open',
                severity: 'warning',
                category: 'tamper',
                createdAt: '2026-11-27T09:00:00Z',
              ),
            ],
            'total': 1,
            'page': 1,
            'limit': 20,
          },
      'GET /v1/alerts/a-open': (_) => _sampleAlert(
            id: 'a-open',
            severity: 'warning',
            category: 'tamper',
            createdAt: '2026-11-27T09:00:00Z',
          ),
      'POST /v1/alerts/a-open/ack': (_) {
        ackCalls++;
        return {'ok': true};
      },
    });

    await tester.pumpWidget(_p14RouterHarness(api: api, p14Enabled: true));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('p14-row-a-open')));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDetailScreen), findsOneWidget);
    expect(ackCalls, 0);
  });

  // Mutant: removing RefreshIndicator from AlertsP14Screen leaves the second
  // alert invisible after fling-down.
  testWidgets('Pull-to-refresh on AlertsP14Screen reloads alerts (#1214)', (tester) async {
    var afterPull = false;
    final api = FakeApiClient({
      ...standardRoutes(),
      'GET /v1/family': (_) => _familyJson(),
      'GET /v1/alerts': (req) {
        if (req.query['ack'] == 'false') {
          return {'items': [], 'total': 0, 'page': 1, 'limit': 50};
        }
        if (!afterPull) {
          return {
            'items': [_sampleAlert(id: 'a1', severity: 'warning', category: 'tamper')],
            'total': 1,
            'page': 1,
            'limit': 20,
          };
        }
        return {
          'items': [
            _sampleAlert(id: 'a2', severity: 'critical', category: 'sos', createdAt: '2026-11-27T09:40:00Z'),
            _sampleAlert(id: 'a1', severity: 'warning', category: 'tamper', createdAt: '2026-11-27T08:00:00Z'),
          ],
          'total': 2,
          'page': 1,
          'limit': 20,
        };
      },
    });

    await tester.pumpWidget(_p14RouterHarness(api: api, p14Enabled: true));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('p14-row-a2')), findsNothing);

    afterPull = true;
    await tester.fling(
      find.byKey(const ValueKey('p14-alerts-list')),
      const Offset(0, 320),
      1000,
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('p14-row-a2')), findsOneWidget);
  });

  // Mutant: removing RefreshIndicator from ChildDetailScreen._AlertsTab leaves
  // the new alert invisible after swipe-down (#1214).
  testWidgets('Pull-to-refresh on ChildDetailScreen Alerts tab re-fetches alerts (#1214)', (tester) async {
    var childAlertCalls = 0;
    final api = FakeApiClient({
      ...standardRoutes(),
      'GET /v1/family': (_) => _familyJson(),
      'GET /v1/alerts': (req) {
        if (req.query['childId'] == 'child-1') {
          childAlertCalls++;
          if (childAlertCalls == 1) {
            return {'items': [], 'total': 0, 'page': 1, 'limit': 20};
          }
          return {
            'items': [
              _sampleAlert(
                id: 'child-new',
                childId: 'child-1',
                severity: 'critical',
                category: 'sos',
                createdAt: '2026-11-27T09:42:00Z',
              ),
            ],
            'total': 1,
            'page': 1,
            'limit': 20,
          };
        }
        return {'items': [], 'total': 0, 'page': 1, 'limit': 20};
      },
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [apiClientProvider.overrideWithValue(api)],
        child: MaterialApp(
          theme: AppTheme.light,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const ChildDetailScreen(childId: 'child-1'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Switch to the Alerts tab on ChildDetailScreen.
    await tester.tap(find.text('Alerts').last);
    await tester.pumpAndSettle();
    expect(find.text('No recent alerts'), findsOneWidget);

    await tester.fling(find.byType(ListView).first, const Offset(0, 320), 1000);
    await tester.pumpAndSettle();
    expect(find.text('SOS pressed'), findsOneWidget);
  });

  // Mutant: showing raw exception strings or crashing on 403/500 fails these
  // error and permission state checks.
  testWidgets('P-14 renders localized error, 403 permission, and empty states', (tester) async {
    // 1) Error / offline state
    final errApi = FakeApiClient({
      ...standardRoutes(),
      'GET /v1/family': (_) => _familyJson(),
      'GET /v1/alerts': (req) {
        if (req.query['ack'] == 'false') {
          return {'items': [], 'total': 0, 'page': 1, 'limit': 50};
        }
        throw DioException(
          requestOptions: RequestOptions(path: '/v1/alerts'),
          type: DioExceptionType.connectionError,
        );
      },
    });
    await tester.pumpWidget(_p14RouterHarness(api: errApi, p14Enabled: true));
    await tester.pumpAndSettle();
    expect(find.text('Retry'), findsOneWidget);
    expect(find.textContaining('DioException'), findsNothing);

    // 2) 403 permission refused state
    final permApi = FakeApiClient({
      ...standardRoutes(),
      'GET /v1/family': (_) => _familyJson(),
      'GET /v1/alerts': (req) {
        if (req.query['ack'] == 'false') {
          return {'items': [], 'total': 0, 'page': 1, 'limit': 50};
        }
        throw DioException(
          requestOptions: RequestOptions(path: '/v1/alerts'),
          response: Response(
            requestOptions: RequestOptions(path: '/v1/alerts'),
            statusCode: 403,
            data: {'error': 'permission_required', 'permission': 'alerts'},
          ),
          type: DioExceptionType.badResponse,
        );
      },
    });
    await tester.pumpWidget(_p14RouterHarness(api: permApi, p14Enabled: true));
    await tester.pumpAndSettle();
    expect(find.textContaining('DioException'), findsNothing);

    // 3) Empty state (Alerts + Requests)
    final emptyApi = FakeApiClient({
      ...standardRoutes(),
      'GET /v1/family': (_) => _familyJson(),
      'GET /v1/alerts': (_) => {'items': [], 'total': 0, 'page': 1, 'limit': 20},
    });
    await tester.pumpWidget(_p14RouterHarness(api: emptyApi, p14Enabled: true));
    await tester.pumpAndSettle();
    expect(find.text('No alerts yet'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('p14-seg-requests')));
    await tester.pumpAndSettle();
    expect(find.text('No requests yet'), findsOneWidget);
  });

  // Mutant: any fixed-width Row in segment bar or alert card overflows at
  // 320x568 @ 2.0x in EN or AR.
  testWidgets('P-14 has zero layout overflows at 320x568 @ 2.0x in EN and AR', (tester) async {
    final api = FakeApiClient({
      ...standardRoutes(),
      'GET /v1/family': (_) => _familyJson(),
      'GET /v1/alerts': (_) => {
            'items': [
              _sampleAlert(
                id: 'a-urgent',
                childId: 'child-1',
                severity: 'critical',
                category: 'sos',
                createdAt: '2026-11-27T09:10:00Z',
              ),
              _sampleAlert(
                id: 'a-grouped',
                childId: 'child-2',
                severity: 'info',
                category: 'web_threat',
                attemptCount: 4,
                createdAt: '2026-11-27T07:00:00Z',
                metadata: {'latestAt': '2026-11-27T09:20:00Z'},
              ),
            ],
            'total': 2,
            'page': 1,
            'limit': 20,
          },
    });

    for (final locale in const [Locale('en'), Locale('ar')]) {
      for (final mode in const [ThemeMode.light, ThemeMode.dark]) {
        tester.view.physicalSize = const Size(640, 1136);
        tester.view.devicePixelRatio = 2.0;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        await tester.pumpWidget(
          _p14RouterHarness(
            api: api,
            p14Enabled: true,
            locale: locale,
            themeMode: mode,
            textScale: 2.0,
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }
    }
  });
}
