import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:familyshield_parent/features/settings/privacy_screen.dart';
import 'package:familyshield_parent/providers/auth_provider.dart';

import 'fake_api_client.dart';
import 'test_app.dart';

/// P-23 Privacy and data. The numbers on this screen are a promise to parents, so the rows pin that
/// every period and the storage place come from `GET /v1/family/privacy`, never from the app.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  Map<String, dynamic> policy({
    int excerpt = 90,
    int alerts = 365,
    int location = 30,
    Map<String, dynamic>? storage = const {'area': 'eu', 'location': 'frankfurt'},
  }) =>
      {
        'retention': {
          'locationDays': location,
          'activityDays': 90,
          'messageExcerptDays': excerpt,
          'dailyTotalsDays': 365,
          'alertDays': alerts,
          'serverLogDays': 90,
          'backupDays': 14,
        },
        'storage': storage,
        'deletionCancelDays': null,
        'policyUrls': {'en': 'https://osratech.com/privacy', 'ar': 'https://osratech.com/privacy'},
      };

  FakeApiClient api({FakeRoute? privacy, Map<String, dynamic>? me, FakeRoute? familyMeRoute}) => FakeApiClient({
        ...standardRoutes(familyMe: me),
        if (familyMeRoute != null) 'GET /v1/family/me': familyMeRoute,
        'GET /v1/family/privacy': privacy ?? (_) => policy(),
      });

  Future<void> pump(WidgetTester tester, FakeApiClient client, {Locale locale = const Locale('en')}) async {
    tester.view.physicalSize = const Size(1080, 6000);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: [apiClientProvider.overrideWithValue(client)],
      child: localizedTestApp(const PrivacyScreen(), locale: locale),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('P1 shows the server periods and storage place, in the unit people say them', (tester) async {
    final client = api();
    await pump(tester, client);

    expect(client.calls('GET', '/v1/family/privacy'), hasLength(1));
    expect(find.text('Flagged message parts'), findsOneWidget);
    expect(find.text('90 days'), findsOneWidget);
    expect(find.text('12 months'), findsOneWidget);
    expect(find.text('30 days'), findsOneWidget);
    expect(find.text('European Union (Frankfurt, Germany)'), findsOneWidget);
    // The mockup's example values must never ship: no UAE storage, no cancel window the server lacks.
    expect(find.textContaining('UAE'), findsNothing);
    expect(find.textContaining('7 days'), findsNothing);
  });

  testWidgets('P2 changed server values change the screen', (tester) async {
    await pump(tester, api(privacy: (_) => policy(excerpt: 60, alerts: 180, location: 14)));

    expect(find.text('60 days'), findsOneWidget);
    expect(find.text('180 days'), findsOneWidget);
    expect(find.text('14 days'), findsOneWidget);
    expect(find.text('90 days'), findsNothing);
  });

  testWidgets('P3 an unknown storage place hides the row instead of guessing', (tester) async {
    await pump(tester, api(privacy: (_) => policy(storage: null)));

    expect(find.byKey(const ValueKey('privacyRowStoredIn')), findsNothing);
    expect(find.byKey(const ValueKey('privacyRowExcerpts')), findsOneWidget);
  });

  testWidgets('P4 a failed load shows a retry, and the actions still work', (tester) async {
    await pump(tester, api(privacy: (_) => const FakeHttpError(500, {'error': 'boom'})));

    expect(find.byKey(const ValueKey('privacyLoadFailed')), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
    expect(find.byKey(const ValueKey('privacyDelete')), findsOneWidget);
    // A server failure is not the parent's connection (R-ID-1, #1195).
    expect(find.text("Couldn't load this right now. Try again in a moment."), findsOneWidget);
    expect(find.textContaining('Check your connection'), findsNothing);
  });

  testWidgets('P4b no connection keeps the connection sentence', (tester) async {
    await pump(tester, api(privacy: (_) => const FakeNetworkError()));

    expect(find.text('Could not load what is kept. Check your connection and try again.'), findsOneWidget);
  });

  testWidgets('P3b a storage place that is not text hides only that row', (tester) async {
    await pump(tester, api(privacy: (_) => policy(storage: const {'area': 'eu', 'location': 42})));

    expect(find.byKey(const ValueKey('privacyLoadFailed')), findsNothing);
    expect(find.byKey(const ValueKey('privacyRowStoredIn')), findsNothing);
    expect(find.byKey(const ValueKey('privacyRowExcerpts')), findsOneWidget);
  });

  testWidgets('P5 the owner is offered the family deletion', (tester) async {
    await pump(tester, api());

    expect(find.text('Delete family account'), findsOneWidget);
    expect(find.text('Delete my account'), findsNothing);
  });

  testWidgets('P6 a co-parent is offered only their own account', (tester) async {
    final me = familyMeTwoChildren();
    (me['parent'] as Map<String, dynamic>)['role'] = 'member';
    await pump(tester, api(me: me));

    expect(find.text('Delete my account'), findsOneWidget);
    expect(find.text('Delete family account'), findsNothing);
  });

  testWidgets('P6b a failed family overview shows retry instead of guessing role or empty children',
      (tester) async {
    var attempts = 0;
    final client = api(
      familyMeRoute: (_) {
        attempts += 1;
        if (attempts == 1) {
          return const FakeHttpError(503, {'error': 'service_unavailable'});
        }
        return familyMeTwoChildren();
      },
    );
    await pump(tester, client);

    expect(find.byKey(const ValueKey('privacyFamilyLoadFailed')), findsOneWidget);
    expect(find.byKey(const ValueKey('privacyFamilyRetry')), findsOneWidget);
    expect(find.byKey(const ValueKey('privacyDelete')), findsNothing);
    expect(find.byKey(const ValueKey('privacyDeleteButton')), findsNothing);
    expect(find.text('Delete my account'), findsNothing);
    expect(find.text('Delete family account'), findsNothing);
    expect(find.byKey(const ValueKey('privacyConsent')), findsNothing);
    // Non-family-scoped rows still work while family overview is unavailable.
    expect(find.byKey(const ValueKey('privacyRowExcerpts')), findsOneWidget);
    expect(find.byKey(const ValueKey('privacyWhoCanSee')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('privacyFamilyRetry')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('privacyFamilyLoadFailed')), findsNothing);
    expect(find.byKey(const ValueKey('privacyDelete')), findsOneWidget);
    expect(find.text('Delete family account'), findsOneWidget);
    expect(find.byKey(const ValueKey('privacyConsent')), findsOneWidget);
  });

  testWidgets('P6c while family overview is loading, delete and consent wait instead of guessing',
      (tester) async {
    final completer = Completer<Object?>();
    final client = api(familyMeRoute: (_) => FakeDeferred(completer.future));

    tester.view.physicalSize = const Size(1080, 6000);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: [apiClientProvider.overrideWithValue(client)],
      child: localizedTestApp(const PrivacyScreen(), locale: const Locale('en')),
    ));
    await tester.pump();

    expect(find.byKey(const ValueKey('privacyFamilyLoading')), findsOneWidget);
    expect(find.byKey(const ValueKey('privacyDelete')), findsNothing);
    expect(find.byKey(const ValueKey('privacyConsent')), findsNothing);
    expect(find.text('Delete my account'), findsNothing);

    completer.complete(familyMeTwoChildren());
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('privacyFamilyLoading')), findsNothing);
    expect(find.byKey(const ValueKey('privacyDelete')), findsOneWidget);
    expect(find.text('Delete family account'), findsOneWidget);
  });

  testWidgets('P7 with two children, consent asks which child first', (tester) async {
    await pump(tester, api());

    await tester.tap(find.byKey(const ValueKey('privacyConsent')));
    await tester.pumpAndSettle();
    expect(find.text('Choose a child'), findsOneWidget);
    expect(find.byKey(const ValueKey('privacyConsentChild-child-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('privacyConsentChild-child-2')), findsOneWidget);
  });

  testWidgets('P8 Arabic uses the Arabic plural forms and right-to-left layout', (tester) async {
    await pump(tester, api(), locale: const Locale('ar'));

    expect(find.text('90 يومًا'), findsOneWidget);
    expect(find.text('12 شهرًا'), findsOneWidget);
    expect(find.text('30 يومًا'), findsOneWidget);
    expect(find.text('الاتحاد الأوروبي (فرانكفورت، ألمانيا)'), findsOneWidget);
    expect(
      Directionality.of(tester.element(find.byKey(const ValueKey('privacyRowExcerpts')))),
      TextDirection.rtl,
    );
  });

  // Mutant: reverting the retention header `Wrap` in `_RetentionCard` back to `Row`
  // causes a 176 px RenderFlex overflow at 320x568 @ 2.0x in Arabic.
  testWidgets('P9 Arabic at 320x568 @ 2.0x renders excerpts and delete rows with zero overflow',
      (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(ProviderScope(
      overrides: [apiClientProvider.overrideWithValue(api())],
      child: MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(2.0)),
        child: localizedTestApp(const PrivacyScreen(), locale: const Locale('ar')),
      ),
    ));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('privacyRowExcerpts')), findsOneWidget);

    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('privacyDelete')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('privacyDelete')), findsOneWidget);
    // At 200% text scale, _DeleteCard stacks the Delete button below the text so the copy gets full width.
    final cardRect = tester.getRect(find.byKey(const ValueKey('privacyDelete')));
    final btnRect = tester.getRect(find.byKey(const ValueKey('privacyDeleteButton')));
    expect(btnRect.top, greaterThan(cardRect.top + 80));
  });
}
