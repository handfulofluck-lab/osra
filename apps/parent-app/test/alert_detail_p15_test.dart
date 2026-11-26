import 'package:familyshield_parent/api/models.dart';
import 'package:familyshield_parent/features/alerts/alert_detail_p15.dart';
import 'package:familyshield_parent/features/alerts/alert_detail_screen.dart';
import 'package:familyshield_parent/l10n/app_localizations.dart';
import 'package:familyshield_parent/providers/auth_provider.dart';
import 'package:familyshield_parent/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'fake_api_client.dart';

Alert _socialAlert({String eventId = 'ev-1'}) => Alert(
      id: 'alert-1',
      childId: 'child-1',
      deviceId: 'dev-1',
      severity: 'high',
      category: 'social_concern',
      title: 'Concerning message',
      body: '',
      createdAt: DateTime.utc(2026, 11, 26, 11, 42),
      metadata: {
        'app': 'whatsapp',
        'contact': 'Jay',
        'concernTypes': ['cyberbullying'],
        'primarySocialEventId': eventId,
        'latestSourceEventId': eventId,
        'socialMessageCount': 2,
      },
    );

FakeApiClient _makeApi({String platform = 'android'}) => FakeApiClient({
      ...standardRoutes(
        familyMe: {
          ...familyMeTwoChildren(),
          'children': [
            {
              'id': 'child-1',
              'familyId': 'fam-1',
              'displayName': 'Alex',
              'birthYear': 2014,
            },
          ],
          'devices': [
            {
              'id': 'dev-1',
              'childId': 'child-1',
              'platform': platform,
              'model': platform == 'ios' ? 'iPhone 15' : 'Galaxy S23',
              'status': 'online',
            },
          ],
        },
      ),
      'GET /v1/social/events': (_) => {
            'items': [
              {
                'id': 'ev-1',
                'childId': 'child-1',
                'app': 'whatsapp',
                'contact': 'Jay',
                'preview': 'Flagged excerpt',
                'createdAt': '2026-11-26T11:42:00Z',
              },
            ],
          },
    });

Widget _harness({
  required FakeApiClient api,
  required bool p15Enabled,
  Locale locale = const Locale('en'),
  ThemeMode themeMode = ThemeMode.light,
  double textScale = 1.0,
}) {
  final router = GoRouter(
    initialLocation: '/alerts/alert-1',
    routes: [
      GoRoute(
        path: '/alerts/:id',
        builder: (_, s) => AlertDetailScreen(
          alertId: s.pathParameters['id']!,
          initialAlert: _socialAlert(),
          nowProvider: () => DateTime.utc(2026, 11, 26, 12, 0),
        ),
      ),
      GoRoute(path: '/alerts', builder: (_, __) => const Scaffold(body: Text('ALERTS'))),
      GoRoute(path: '/child/:id/social', builder: (_, __) => const Scaffold(body: Text('SOCIAL'))),
      GoRoute(path: '/child/:id/rules', builder: (_, __) => const Scaffold(body: Text('RULES'))),
    ],
  );
  return ProviderScope(
    key: UniqueKey(),
    overrides: [
      apiClientProvider.overrideWithValue(api),
      p15AlertDetailEnabledProvider.overrideWithValue(p15Enabled),
    ],
    child: MaterialApp.router(
      locale: locale,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: themeMode,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      routerConfig: router,
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  testWidgets('P-15 ON shows sender (#1059), can-be-wrong framing, Fix 2 Help Alex block Jay, #1065 vote footer, and NO Mark reviewed / encrypted banner',
      (tester) async {
    final api = _makeApi();
    await tester.pumpWidget(_harness(api: api, p15Enabled: true));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('p15AlertDetailScroll')), findsOneWidget);
    expect(find.byKey(const ValueKey('p15Sender')), findsOneWidget);
    expect(find.textContaining('Jay'), findsWidgets);
    expect(find.byKey(const ValueKey('p15CanBeWrong')), findsOneWidget);

    // Forbidden elements: no "Mark reviewed", no "encrypted on device".
    expect(find.textContaining('Mark reviewed'), findsNothing);
    expect(find.textContaining('encrypted on device'), findsNothing);

    await tester.scrollUntilVisible(find.byKey(const ValueKey('p15Action-helpBlock')), 150);
    expect(find.textContaining('Help'), findsWidgets);
    expect(find.textContaining('block'), findsWidgets);

    await tester.scrollUntilVisible(find.byKey(const ValueKey('p15VoteFooter')), 150);
    expect(find.byKey(const ValueKey('p15VoteFooter')), findsOneWidget);
    expect(find.text('Was OSRA right to flag this?'), findsOneWidget);
    expect(find.text('Concerning'), findsOneWidget);
    expect(find.text('Not concerning'), findsOneWidget);
  });

  testWidgets('P-15 ON shows iPhone Not yet available state for iPhone-only child (Fix 8)', (tester) async {
    final api = _makeApi(platform: 'ios');
    await tester.pumpWidget(_harness(api: api, p15Enabled: true));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('p15IphoneNotYet')), findsOneWidget);
    expect(find.text('Not yet available on iPhone'), findsOneWidget);
  });

  testWidgets('P-15 OFF falls back to legacy _SocialAlertDetailBody', (tester) async {
    final api = _makeApi();
    await tester.pumpWidget(_harness(api: api, p15Enabled: false));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('alertDetailScroll')), findsOneWidget);
    expect(find.byKey(const ValueKey('p15AlertDetailScroll')), findsNothing);
  });

  testWidgets('Bureau 8-combo matrix: zero overflow across EN/AR x light/dark x 390/320-200%',
      (tester) async {
    final api = _makeApi();
    for (final locale in const [Locale('en'), Locale('ar')]) {
      for (final mode in const [ThemeMode.light, ThemeMode.dark]) {
        for (final (size, scale) in const [
          (Size(390, 844), 1.0),
          (Size(320, 568), 2.0),
        ]) {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1.0;
          addTearDown(tester.view.reset);

          await tester.pumpWidget(_harness(
            api: api,
            p15Enabled: true,
            locale: locale,
            themeMode: mode,
            textScale: scale,
          ));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull,
              reason: 'Failed on $locale $mode $size @ ${scale}x');
        }
      }
    }
  });
}
