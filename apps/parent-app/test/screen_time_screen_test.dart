import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:familyshield_parent/features/rules/screen_time_screen.dart';
import 'package:familyshield_parent/l10n/app_localizations.dart';
import 'package:familyshield_parent/providers/auth_provider.dart';
import 'package:familyshield_parent/providers/clock_provider.dart';
import 'package:familyshield_parent/theme/app_theme.dart';

import 'fake_api_client.dart';

/// P-10 Screen time. The ring has to show the limit the child's phone applies today (school days vs
/// Saturday/Sunday, `RuleEngine.kt`), and the steppers have to write only the limit they change.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  // 2026-11-26 is a Thursday, 2026-11-28 a Saturday.
  final thursday = DateTime(2026, 11, 26, 10);
  final saturday = DateTime(2026, 11, 28, 10);

  Map<String, dynamic> rules({int daily = 120, int weekend = 240, List<String> always = const []}) {
    final r = ruleSetPayload('child-1', alwaysAllowedApps: always);
    r['screenTime'] = {...(r['screenTime'] as Map<String, dynamic>), 'dailyLimitMinutes': daily, 'weekendLimitMinutes': weekend};
    return r;
  }

  Map<String, dynamic> usage(List<Map<String, dynamic>> apps) => {
        'childId': 'child-1',
        'days': 1,
        'totalMinutes': apps.fold<int>(0, (n, a) => n + (a['minutes'] as int)),
        'series': [
          {'day': '2026-11-26', 'minutes': apps.fold<int>(0, (n, a) => n + (a['minutes'] as int)), 'apps': apps},
        ],
      };

  FakeApiClient api({
    Map<String, dynamic>? ruleSet,
    Map<String, dynamic>? me,
    Map<String, dynamic>? usageBody,
    FakeRoute? patch,
  }) =>
      FakeApiClient({
        ...standardRoutes(familyMe: me),
        'GET /v1/rules/child-1': (_) => ruleSet ?? rules(),
        if (patch != null) 'PATCH /v1/rules/child-1': patch,
        'GET /v1/controls/children/child-1/status': (_) => {'paused': false},
        'POST /v1/controls/children/child-1/bonus': (_) => {'ok': true},
        'GET /v1/reports/usage': (_) => usageBody ?? usage(const []),
      });

  Future<void> pump(
    WidgetTester tester,
    FakeApiClient client, {
    DateTime? now,
    Locale locale = const Locale('en'),
    Size size = const Size(390, 3000),
    double textScale = 1,
    bool dark = false,
  }) async {
    tester.view.physicalSize = size * 3;
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(client),
        clockProvider.overrideWithValue(() => now ?? thursday),
      ],
      child: MaterialApp(
        locale: locale,
        theme: dark ? AppTheme.dark : AppTheme.light,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, inner) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
          child: inner!,
        ),
        home: const ScreenTimeScreen(childId: 'child-1'),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('S1 a school day uses the school-day limit', (tester) async {
    await pump(tester, api());

    // Alex has used 45 min (familyMeTwoChildren) of a 2 h school-day limit.
    expect(find.text('1 h 15 min left today'), findsOneWidget);
    expect(find.text('45 min used of 2 h'), findsOneWidget);
    expect(find.byKey(const ValueKey('screenTimeValue-schoolDays')), findsOneWidget);
    expect(find.text('2 h'), findsOneWidget);
    expect(find.text('4 h'), findsOneWidget);
  });

  testWidgets('S2 Saturday uses the weekend limit, like the child phone', (tester) async {
    await pump(tester, api(), now: saturday);

    expect(find.text('3 h 15 min left today'), findsOneWidget);
    expect(find.text('45 min used of 4 h'), findsOneWidget);
  });

  testWidgets('S3 a stepper writes only its own limit, in 15-minute steps', (tester) async {
    final client = api();
    await pump(tester, client);

    await tester.tap(find.byKey(const ValueKey('screenTimeMore-schoolDays')));
    await tester.pumpAndSettle();

    final patches = client.calls('PATCH', '/v1/rules/child-1');
    expect(patches, hasLength(1));
    expect(patches.single.data, {
      'screenTime': {'dailyLimitMinutes': 135},
    });
    expect(find.text('Saved. The phone picks it up when it next checks in.'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('screenTimeLess-weekend')));
    await tester.pumpAndSettle();
    expect(client.calls('PATCH', '/v1/rules/child-1').last.data, {
      'screenTime': {'weekendLimitMinutes': 225},
    });
  });

  testWidgets('S4 no school-day limit means no limit at all, and the weekend waits for one', (tester) async {
    await pump(tester, api(ruleSet: rules(daily: 0)));

    expect(find.text('45 min used today'), findsOneWidget);
    expect(find.text('No daily limit is set'), findsOneWidget);
    expect(find.text('Set a school-day limit first'), findsOneWidget);
    final less = tester.widget<IconButton>(find.byKey(const ValueKey('screenTimeLess-weekend')));
    final more = tester.widget<IconButton>(find.byKey(const ValueKey('screenTimeMore-weekend')));
    expect(less.onPressed, isNull);
    expect(more.onPressed, isNull);
  });

  testWidgets('S5 a weekend left at 0 reads as the school-day limit', (tester) async {
    await pump(tester, api(ruleSet: rules(weekend: 0)), now: saturday);

    expect(find.text('1 h 15 min left today'), findsOneWidget);
    expect(find.textContaining('Same as school days'), findsOneWidget);
  });

  testWidgets('S6 over the limit says by how much', (tester) async {
    await pump(tester, api(ruleSet: rules(daily: 30)));

    expect(find.text('15 min over today\'s limit'), findsOneWidget);
  });

  testWidgets('S7 extra time posts the bonus for today', (tester) async {
    final client = api();
    await pump(tester, client);

    await tester.tap(find.byKey(const ValueKey('screenTimeAdd30')));
    await tester.pumpAndSettle();

    final posts = client.calls('POST', '/v1/controls/children/child-1/bonus');
    expect(posts, hasLength(1));
    expect(posts.single.data, {'minutes': 30});
  });

  testWidgets('S8 where the time went names apps, never package ids', (tester) async {
    await pump(
      tester,
      api(usageBody: usage([
        {'app': 'com.example.video', 'minutes': 12},
        {'app': 'com.example.game', 'minutes': 30},
      ])),
    );

    expect(find.textContaining('Game'), findsOneWidget);
    expect(find.textContaining('Video'), findsOneWidget);
    expect(find.textContaining('com.example'), findsNothing);
    final gameY = tester.getTopLeft(find.textContaining('Game')).dy;
    final videoY = tester.getTopLeft(find.textContaining('Video')).dy;
    expect(gameY, lessThan(videoY));
  });

  testWidgets('S9 no use yet says so', (tester) async {
    await pump(tester, api());

    expect(find.text('No app use reported yet today'), findsOneWidget);
  });

  testWidgets('S10 an iPhone child gets the "Not yet available" line', (tester) async {
    await pump(tester, api(me: familyMeTwoChildren(alexPlatform: 'ios')));

    expect(find.byKey(const ValueKey('screenTimeIphoneNote')), findsOneWidget);
  });

  testWidgets('S11 never counted links to the always-allowed apps', (tester) async {
    await pump(tester, api(ruleSet: rules(always: ['com.example.reader', 'com.example.game'])));

    expect(find.text('2 apps are always allowed'), findsOneWidget);
  });

  testWidgets('S12 switching child chips shows that child', (tester) async {
    final client = api();
    await pump(tester, client);
    await tester.tap(find.byKey(const ValueKey('screenTimeChild-child-2')));
    await tester.pumpAndSettle();

    expect(client.calls('GET', '/v1/rules/child-2'), isNotEmpty);
    // Sam has used 10 min of the fixture's 2 h school-day limit.
    expect(find.text('1 h 50 min left today'), findsOneWidget);
  });

  testWidgets('S13 Arabic reads right to left with Arabic plurals', (tester) async {
    await pump(tester, api(), locale: const Locale('ar'));

    expect(find.textContaining('متبقٍ'), findsOneWidget);
    expect(find.text('أيام الدراسة'), findsOneWidget);
    final dir = Directionality.of(tester.element(find.byKey(const ValueKey('screenTimeToday'))));
    expect(dir, TextDirection.rtl);
  });

  for (final dark in [false, true]) {
    for (final locale in const [Locale('en'), Locale('ar')]) {
      testWidgets('S14 320 px at 200% text fits (${locale.languageCode}, ${dark ? 'dark' : 'light'})', (tester) async {
        await pump(tester, api(me: familyMeTwoChildren(alexPlatform: 'ios')),
            locale: locale, size: const Size(320, 4000), textScale: 2, dark: dark);

        expect(tester.takeException(), isNull);
        expect(find.byKey(const ValueKey('screenTimeMore-weekend')), findsOneWidget);
        final button = tester.getSize(find.byKey(const ValueKey('screenTimeMore-weekend')));
        expect(button.width, greaterThanOrEqualTo(48));
        expect(button.height, greaterThanOrEqualTo(48));
      });
    }
  }
}
