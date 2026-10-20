import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:familyshield_parent/api/models.dart' show kRecommendedCategories;
import 'package:familyshield_parent/app.dart' show FamilyShieldApp, router;
import 'package:familyshield_parent/features/alerts/alerts_screen.dart';
import 'package:familyshield_parent/features/auth/login_screen.dart';
import 'package:familyshield_parent/features/children/child_detail_screen.dart';
import 'package:familyshield_parent/features/dashboard/dashboard_screen.dart';
import 'package:familyshield_parent/features/rules/rules_editor_screen.dart';
import 'package:familyshield_parent/providers/auth_provider.dart';
import 'package:familyshield_parent/providers/onboarding_provider.dart';

import 'fake_api_client.dart';
import 'test_app.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    // These tests exercise the normal login/dashboard routing; the first-run
    // wizard has its own suite (test/onboarding_test.dart).
    SharedPreferences.setMockInitialValues({kOnboardingCompleteKey: true});
  });

  /// Pumps [home] inside a ProviderScope with the fake API client. When
  /// [surface] is given, the logical screen size is set (and reset afterwards).
  Future<void> pumpScreen(WidgetTester tester, Widget home, FakeApiClient api, {Size? surface}) async {
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
      child: localizedTestApp(home),
    ));
    await tester.pumpAndSettle();
  }

  /// Drains every exception recorded by the test binding (layout overflows
  /// surface here); callers assert the list is empty.
  List<Object> drainExceptions(WidgetTester tester) {
    final exceptions = <Object>[];
    while (true) {
      final e = tester.takeException();
      if (e == null) return exceptions;
      exceptions.add(e);
    }
  }

  /// Lets a fake-Dio request chain complete: Dio dispatches through chained
  /// zero-duration Timers, which only fire when fake time advances — bare
  /// pump() does not advance it and pumpAndSettle may return before the chain
  /// finishes, so pump with explicit durations instead.
  Future<void> flushFakeHttp(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  /// Finds the TextField whose InputDecoration label is [label].
  Finder fieldByLabel(String label) => find.ancestor(of: find.text(label), matching: find.byType(TextField));

  /// Scrolls the Sign in button into view (the MFA code field can push it
  /// below the fold on the small default test viewport) and taps it.
  Future<void> tapSignIn(WidgetTester tester) async {
    await tester.scrollUntilVisible(find.text('Sign in'), 100, scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sign in'));
  }

  /// The vertical Scrollable of the rules editor's web-filter list (the
  /// TextFields inside it carry their own horizontal Scrollables).
  Finder webFilterScrollable() => find.descendant(
        of: find.byKey(const ValueKey('webFilterList')),
        matching: find.byWidgetPredicate((w) => w is Scrollable && w.axis == Axis.vertical),
      );

  group('LoginScreen', () {
    testWidgets('renders server, email and password fields', (tester) async {
      final api = FakeApiClient(standardRoutes());
      await pumpScreen(tester, const LoginScreen(), api);

      expect(find.text('OSRA'), findsOneWidget);
      expect(fieldByLabel('Server'), findsOneWidget);
      expect(fieldByLabel('Email'), findsOneWidget);
      expect(fieldByLabel('Password'), findsOneWidget);
      expect(fieldByLabel('Authentication code (if MFA is on)'), findsOneWidget);
      expect(find.text('Sign in'), findsOneWidget);
    });

    testWidgets('invalid server URL shows an inline error and skips the login call', (tester) async {
      final api = FakeApiClient(standardRoutes());
      await pumpScreen(tester, const LoginScreen(), api);

      // 'http://' has no host — invalid. (Hyphenated single-label hostnames like
      // 'my-server' are now accepted LAN hosts, so they can't serve as the bad input.)
      await tester.enterText(fieldByLabel('Server'), 'http://');
      await tapSignIn(tester);
      await tester.pumpAndSettle();

      expect(find.text('Enter a valid server, e.g. http://192.168.1.5:3000'), findsOneWidget);
      expect(api.calls('POST', '/v1/auth/login'), isEmpty);
    });

    testWidgets('failed sign-in shows the server error text', (tester) async {
      final api = FakeApiClient(standardRoutes());
      await pumpScreen(tester, const LoginScreen(), api);

      await tester.enterText(fieldByLabel('Server'), 'http://testserver');
      await tester.enterText(fieldByLabel('Email'), 'qa@familyshield.dev');
      await tester.enterText(fieldByLabel('Password'), 'wrong-password');
      await tapSignIn(tester);
      await tester.pumpAndSettle();

      expect(api.calls('POST', '/v1/auth/login'), hasLength(1));
      expect(find.text('invalid_credentials'), findsOneWidget);
    });

    // NOTE: success navigation is asserted by pumping the REAL app router
    // (FamilyShieldApp from lib/app.dart) — so the auth redirect and the
    // context.go('/') in LoginScreen._submit are exercised end-to-end.
    testWidgets('successful sign-in navigates to the dashboard', (tester) async {
      final api = FakeApiClient(standardRoutes());
      await tester.pumpWidget(ProviderScope(
        overrides: [apiClientProvider.overrideWithValue(api)],
        child: const FamilyShieldApp(),
      ));
      await tester.pumpAndSettle();
      expect(find.byType(LoginScreen), findsOneWidget);

      await tester.enterText(fieldByLabel('Server'), 'http://testserver');
      await tester.enterText(fieldByLabel('Email'), 'qa@familyshield.dev');
      await tester.enterText(fieldByLabel('Password'), 'good-password');
      await tapSignIn(tester);
      await tester.pumpAndSettle();

      expect(router.routerDelegate.currentConfiguration.uri.path, '/');
      expect(find.byType(DashboardScreen), findsOneWidget);
      expect(find.text('Alex'), findsOneWidget);
      expect(find.text('Sam'), findsOneWidget);
    });
  });

  group('DashboardScreen', () {
    testWidgets('renders child cards with status chips; battery chip hidden at 0%', (tester) async {
      final api = FakeApiClient(standardRoutes());
      await pumpScreen(tester, const DashboardScreen(), api);

      expect(find.text('Alex'), findsOneWidget);
      expect(find.text('Sam'), findsOneWidget);
      // Alex's device checked in just now → online; Sam's is 2h stale → offline.
      expect(find.text('online'), findsOneWidget);
      expect(find.text('offline'), findsOneWidget);
      // Battery chip shown for 55%, hidden for 0%.
      expect(find.text('55%'), findsOneWidget);
      expect(find.text('0%'), findsNothing);
    });

    testWidgets('device shows offline when lastSeen is older than 3 minutes', (tester) async {
      final api = FakeApiClient(standardRoutes());
      await pumpScreen(tester, const DashboardScreen(), api);

      // Sam's device reported status 'online' from the server but its lastSeen
      // is 2h old, so the card must derive 'offline'.
      final samCard = find.ancestor(of: find.text('Sam'), matching: find.byType(Card));
      expect(find.descendant(of: samCard, matching: find.text('offline')), findsOneWidget);
      expect(find.descendant(of: samCard, matching: find.text('online')), findsNothing);
    });

    testWidgets('pull-to-refresh refetches the family overview', (tester) async {
      final api = FakeApiClient(standardRoutes());
      await pumpScreen(tester, const DashboardScreen(), api);
      expect(api.calls('GET', '/v1/family/me'), hasLength(1));

      await tester.fling(find.byType(GridView), const Offset(0, 400), 900);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();

      expect(api.calls('GET', '/v1/family/me').length, greaterThanOrEqualTo(2));
    });

    testWidgets('FAB opens the add-child dialog; creating a child POSTs with consent', (tester) async {
      final api = FakeApiClient(standardRoutes());
      await pumpScreen(tester, const DashboardScreen(), api);

      await tester.tap(find.text('Add child'));
      await tester.pumpAndSettle();
      expect(find.text('Parental consent'), findsOneWidget);

      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(find.text('Child details'), findsOneWidget);

      await tester.enterText(fieldByLabel('Child name'), 'New Kid');
      final dialog = find.byType(AlertDialog);
      await tester.tap(find.descendant(of: dialog, matching: find.text('Add child')));
      await tester.pumpAndSettle();

      final posts = api.calls('POST', '/v1/family/children');
      expect(posts, hasLength(1));
      expect(posts.single.body['displayName'], 'New Kid');
      expect(posts.single.body['consent'], isA<Map>());
      expect((posts.single.body['consent'] as Map)['jurisdiction'], 'US');
      // Dialog closed and the family was refetched.
      expect(find.byType(AlertDialog), findsNothing);
      expect(api.calls('GET', '/v1/family/me').length, greaterThanOrEqualTo(2));
    });

    testWidgets('alerts icon shows the unacknowledged badge count', (tester) async {
      final api = FakeApiClient(standardRoutes(unacked: 3));
      await pumpScreen(tester, const DashboardScreen(), api);

      final badge = find.byType(Badge);
      expect(badge, findsOneWidget);
      expect(find.descendant(of: badge, matching: find.text('3')), findsOneWidget);
    });
  });

  group('ChildDetailScreen Overview tab', () {
    testWidgets('renders the device card with fresh status and battery chip', (tester) async {
      final api = FakeApiClient(standardRoutes());
      await pumpScreen(tester, const ChildDetailScreen(childId: 'child-1'), api);

      expect(find.text('Pixel 7a'), findsOneWidget);
      expect(find.text('android 14 · online'), findsOneWidget);
      expect(find.text('55%'), findsOneWidget);
      expect(find.text('Last seen: never'), findsNothing);
    });

    testWidgets('stale device shows offline and 0% battery chip is hidden', (tester) async {
      final api = FakeApiClient(standardRoutes());
      await pumpScreen(tester, const ChildDetailScreen(childId: 'child-2'), api);

      expect(find.text('Galaxy A14'), findsOneWidget);
      expect(find.text('android 13 · offline'), findsOneWidget);
      expect(find.text('0%'), findsNothing);
    });

    testWidgets('Ring/Lock/Unlock POST device commands and confirm via snackbar', (tester) async {
      final api = FakeApiClient(standardRoutes());
      await pumpScreen(tester, const ChildDetailScreen(childId: 'child-1'), api);

      for (final (label, command) in [('Ring', 'ring'), ('Lock', 'lock'), ('Unlock', 'unlock')]) {
        await tester.tap(find.text(label));
        await flushFakeHttp(tester);
        expect(find.textContaining('$label queued for Pixel 7a'), findsOneWidget);
        // Plan 3.6: the toast must not claim delivery for a pending command.
        expect(find.textContaining(RegExp(r'\bsent\b', caseSensitive: false)), findsNothing);
        expect(api.calls('POST', '/v1/devices/dev-1/command').last.body['command'], command);
        // Run out the 4s snackbar before the next command — ScaffoldMessenger
        // queues snackbars, and pumpAndSettle alone returns while the display
        // timer is still pending.
        await tester.pump(const Duration(seconds: 5));
        await tester.pumpAndSettle();
      }

      final posts = api.calls('POST', '/v1/devices/dev-1/command');
      expect(posts, hasLength(3));
    });

    testWidgets('a refused command reports the reason instead of "queued"', (tester) async {
      // Issue #221: the API refuses a locate_now the phone's last telemetry says it cannot answer.
      // The toast must carry the reason; saying "queued" is the silent failure the refusal removes.
      final api = FakeApiClient({
        ...standardRoutes(),
        'POST /v1/devices/dev-1/command': (_) => {
              'published': false,
              'status': 'failed',
              'reason': 'background_location_missing',
            },
      });
      await pumpScreen(tester, const ChildDetailScreen(childId: 'child-1'), api);

      await tester.tap(find.text('Lock'));
      await flushFakeHttp(tester);

      expect(find.textContaining('Allow all the time'), findsOneWidget);
      expect(find.textContaining('not sent'), findsOneWidget);
      expect(find.textContaining('queued'), findsNothing);
    });

    testWidgets('a lock refused because the lock screen cannot appear shows the reason', (tester) async {
      // Issue #231 review D1: the agent refuses a lock when overlay, accessibility and the keyguard
      // are all unavailable. The toast must name the fix ("Display over other apps"), never "queued".
      final api = FakeApiClient({
        ...standardRoutes(),
        'POST /v1/devices/dev-1/command': (_) => {
              'published': false,
              'status': 'failed',
              'reason': 'lock_screen_unavailable',
            },
      });
      await pumpScreen(tester, const ChildDetailScreen(childId: 'child-1'), api);

      await tester.tap(find.text('Lock'));
      await flushFakeHttp(tester);

      expect(find.textContaining('Display over other apps'), findsOneWidget);
      expect(find.textContaining('queued'), findsNothing);
    });

    testWidgets('a command the device settled failed shows why on the card', (tester) async {
      // Issue #231: this refusal arrives as an ack after the POST returned `pending`, so the card is
      // often the only place the parent ever sees the reason.
      final api = FakeApiClient({
        ...standardRoutes(),
        'GET /v1/devices/dev-1/commands/history': (_) => {
              'items': [
                commandJson('cmd-failed', 'lock', 'failed', DateTime.now().subtract(const Duration(minutes: 3)),
                    deliveredAt: DateTime.now().subtract(const Duration(minutes: 3)),
                    ackedAt: DateTime.now().subtract(const Duration(minutes: 2)),
                    result: const {'reason': 'lock_screen_unavailable'}),
              ],
            },
      });
      await pumpScreen(tester, const ChildDetailScreen(childId: 'child-1'), api);

      expect(
        find.textContaining("The lock screen can't appear on your child's phone"),
        findsOneWidget,
      );
    });

    testWidgets('an unknown refusal reason still names the code, not "queued"', (tester) async {
      final api = FakeApiClient({
        ...standardRoutes(),
        'POST /v1/devices/dev-1/command': (_) => {
              'published': false,
              'status': 'failed',
              'reason': 'some_new_reason',
            },
      });
      await pumpScreen(tester, const ChildDetailScreen(childId: 'child-1'), api);

      await tester.tap(find.text('Lock'));
      await flushFakeHttp(tester);

      expect(find.textContaining('some_new_reason'), findsOneWidget);
      expect(find.textContaining('queued'), findsNothing);
    });
  });

  group('Internet pause pill (Feature #11)', () {
    /// Route table with a stateful controls status so the refetch after a
    /// successful POST reflects the new paused state (mirrors the server).
    FakeApiClient pausedApi({required bool startPaused}) {
      var paused = startPaused;
      return FakeApiClient({
        ...standardRoutes(),
        'GET /v1/controls/children/child-1/status': (_) => {'paused': paused},
        'GET /v1/controls/children/child-2/status': (_) => {'paused': false},
        'POST /v1/controls/children/child-1/pause': (_) {
          paused = true;
          return {'ok': true};
        },
        'POST /v1/controls/children/child-1/resume': (_) {
          paused = false;
          return {'ok': true};
        },
      });
    }

    testWidgets('pill shows Paused when the controls status is true', (tester) async {
      final api = pausedApi(startPaused: true);
      await pumpScreen(tester, const DashboardScreen(), api);

      final alexCard = find.ancestor(of: find.text('Alex'), matching: find.byType(Card));
      expect(find.descendant(of: alexCard, matching: find.text('Paused')), findsOneWidget);
      expect(find.descendant(of: alexCard, matching: find.text('Internet')), findsNothing);
      // Sam's status is false → green pill.
      final samCard = find.ancestor(of: find.text('Sam'), matching: find.byType(Card));
      expect(find.descendant(of: samCard, matching: find.text('Internet')), findsOneWidget);
    });

    testWidgets('tap → confirm dialog → POSTs pause and flips the pill', (tester) async {
      final api = pausedApi(startPaused: false);
      await pumpScreen(tester, const DashboardScreen(), api);
      final alexCard = find.ancestor(of: find.text('Alex'), matching: find.byType(Card));
      expect(find.descendant(of: alexCard, matching: find.text('Internet')), findsOneWidget);

      await tester.tap(find.descendant(of: alexCard, matching: find.text('Internet')));
      await tester.pumpAndSettle();
      expect(find.text('Pause internet for Alex?'), findsOneWidget);
      expect(find.text('Educational apps keep working.'), findsOneWidget);

      await tester.tap(find.text('Pause'));
      await flushFakeHttp(tester);
      await tester.pumpAndSettle();

      expect(api.calls('POST', '/v1/controls/children/child-1/pause'), hasLength(1));
      expect(find.descendant(of: alexCard, matching: find.text('Paused')), findsOneWidget);
    });

    testWidgets('cancel on the confirm dialog keeps the pill unchanged and skips the POST', (tester) async {
      final api = pausedApi(startPaused: false);
      await pumpScreen(tester, const DashboardScreen(), api);
      final alexCard = find.ancestor(of: find.text('Alex'), matching: find.byType(Card));

      await tester.tap(find.descendant(of: alexCard, matching: find.text('Internet')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(api.calls('POST', '/v1/controls/children/child-1/pause'), isEmpty);
      expect(find.descendant(of: alexCard, matching: find.text('Internet')), findsOneWidget);
    });

    testWidgets('paused pill → confirm resume → POSTs resume and flips back', (tester) async {
      final api = pausedApi(startPaused: true);
      await pumpScreen(tester, const DashboardScreen(), api);
      final alexCard = find.ancestor(of: find.text('Alex'), matching: find.byType(Card));
      expect(find.descendant(of: alexCard, matching: find.text('Paused')), findsOneWidget);

      await tester.tap(find.descendant(of: alexCard, matching: find.text('Paused')));
      await tester.pumpAndSettle();
      expect(find.text('Resume internet for Alex?'), findsOneWidget);

      await tester.tap(find.text('Resume'));
      await flushFakeHttp(tester);
      await tester.pumpAndSettle();

      expect(api.calls('POST', '/v1/controls/children/child-1/resume'), hasLength(1));
      expect(find.descendant(of: alexCard, matching: find.text('Internet')), findsOneWidget);
    });

    testWidgets('404 status is treated as not paused', (tester) async {
      // standardRoutes has no controls routes — the fake answers 404.
      final api = FakeApiClient(standardRoutes());
      await pumpScreen(tester, const DashboardScreen(), api);

      expect(api.calls('GET', '/v1/controls/children/child-1/status'), hasLength(1));
      final alexCard = find.ancestor(of: find.text('Alex'), matching: find.byType(Card));
      expect(find.descendant(of: alexCard, matching: find.text('Internet')), findsOneWidget);
      expect(find.text('Paused'), findsNothing);
    });

    testWidgets('child detail Pause net button POSTs the pause endpoint', (tester) async {
      final api = pausedApi(startPaused: false);
      await pumpScreen(tester, const ChildDetailScreen(childId: 'child-1'), api);

      await tester.tap(find.text('Pause net'));
      await flushFakeHttp(tester);

      expect(api.calls('POST', '/v1/controls/children/child-1/pause'), hasLength(1));
      expect(find.text('Resume net'), findsOneWidget);
      // Run out the snackbar so no timer is left pending at test end.
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    });
  });

  group('Pairing screen', () {
    // NOTE: no pumpAndSettle while the pairing screen is open — its 1s
    // countdown timer would make pumpAndSettle time out. Short pumps flush the
    // fake POST.
    Future<void> openPairing(WidgetTester tester, FakeApiClient api) async {
      await pumpScreen(tester, const ChildDetailScreen(childId: 'child-1'), api);
      await tester.tap(find.text('Pair a device'));
      await flushFakeHttp(tester);
    }

    /// Pops the pairing route and lets the countdown timer dispose.
    Future<void> closePairing(WidgetTester tester) async {
      await tester.pageBack();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
    }

    testWidgets('POSTs /v1/devices/pair on open and shows the QR and the 6-digit code', (tester) async {
      final api = FakeApiClient(standardRoutes());
      await openPairing(tester, api);

      final posts = api.calls('POST', '/v1/devices/pair');
      expect(posts, hasLength(1));
      expect(posts.single.body['childId'], 'child-1');
      expect(find.text('482916'), findsOneWidget);
      expect(find.textContaining('Expires in'), findsOneWidget);
      expect(find.byKey(const ValueKey('pairingQr')), findsOneWidget);

      await closePairing(tester);
    });

    testWidgets('Regenerate button re-POSTs the pair request', (tester) async {
      final api = FakeApiClient(standardRoutes());
      await openPairing(tester, api);

      await tester.tap(find.byKey(const ValueKey('pairingRegenerate')));
      await flushFakeHttp(tester);

      expect(api.calls('POST', '/v1/devices/pair'), hasLength(2));
      expect(find.text('482916'), findsOneWidget);

      await closePairing(tester);
    });
  });

  group('AlertsScreen', () {
    Color severityIconColor(WidgetTester tester, String title) {
      final tile = find.ancestor(of: find.text(title), matching: find.byType(AlertTile));
      return tester.widget<Icon>(find.descendant(of: tile, matching: find.byIcon(Icons.circle))).color!;
    }

    testWidgets('severity icons are colored and the list is grouped by day', (tester) async {
      final alertItems = defaultAlerts();
      final api = FakeApiClient(standardRoutes(alerts: alertItems));
      await pumpScreen(tester, const AlertsScreen(), api);

      expect(severityIconColor(tester, 'SOS pressed'), Colors.red);
      expect(severityIconColor(tester, 'Blocked site visited'), Colors.amber);
      expect(severityIconColor(tester, 'Daily limit reached'), Colors.blue);

      // Grouped under one header per distinct local day.
      String dayLabel(DateTime at) => DateFormat('EEEE, MMM d, yyyy').format(DateTime(at.year, at.month, at.day));
      final days = {
        for (final a in alertItems) dayLabel(DateTime.parse(a['createdAt'] as String).toLocal()),
      };
      for (final day in days) {
        expect(find.text(day), findsOneWidget);
      }
      expect(days.length, greaterThanOrEqualTo(2));
    });

    testWidgets('swiping an alert dismisses it and POSTs the ack', (tester) async {
      final api = FakeApiClient(standardRoutes());
      await pumpScreen(tester, const AlertsScreen(), api);
      expect(find.text('SOS pressed'), findsOneWidget);

      await tester.drag(find.text('SOS pressed'), const Offset(-600, 0));
      await flushFakeHttp(tester);
      await tester.pumpAndSettle();

      expect(api.calls('POST', '/v1/alerts/a3/ack'), hasLength(1));
      expect(find.text('SOS pressed'), findsNothing);
      expect(find.text('Blocked site visited'), findsOneWidget);
    });

    testWidgets('shows an empty state when there are no alerts', (tester) async {
      final api = FakeApiClient(standardRoutes(alerts: const []));
      await pumpScreen(tester, const AlertsScreen(), api);

      expect(find.text('No alerts yet'), findsOneWidget);
      expect(find.byType(AlertTile), findsNothing);
    });
  });

  group('RulesEditorScreen', () {
    Future<void> pumpRules(WidgetTester tester, FakeApiClient api) =>
        pumpScreen(tester, const RulesEditorScreen(childId: 'child-1'), api);

    testWidgets('screen-time slider changes the daily limit text', (tester) async {
      final api = FakeApiClient(standardRoutes());
      await pumpRules(tester, api);

      expect(find.text('Daily limit: 120 min'), findsOneWidget);
      await tester.drag(find.byType(Slider).first, const Offset(200, 0));
      await tester.pumpAndSettle();

      expect(find.text('Daily limit: 120 min'), findsNothing);
      final label = tester.widgetList<Text>(find.byWidgetPredicate(
        (w) => w is Text && (w.data ?? '').startsWith('Daily limit:'),
      ));
      expect(label, hasLength(1));
      expect(label.single.data, matches(RegExp(r'^Daily limit: \d+ min$')));
    });

    testWidgets('SafeSearch switch toggles the web-filter model', (tester) async {
      final api = FakeApiClient(standardRoutes());
      await pumpRules(tester, api);

      await tester.tap(find.text('Web filter'));
      await tester.pumpAndSettle();
      final tile = find.widgetWithText(SwitchListTile, 'Enforce SafeSearch');
      // The recommended-protection header pushed this tile below the fold.
      await tester.scrollUntilVisible(tile, 150, scrollable: webFilterScrollable());
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(tile).value, isTrue);
      await tester.tap(tile);
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(tile).value, isFalse);
    });

    testWidgets('add and remove an app rule row', (tester) async {
      final api = FakeApiClient(standardRoutes());
      await pumpRules(tester, api);

      await tester.tap(find.text('Apps'));
      await tester.pumpAndSettle();
      expect(find.text('com.example.game'), findsOneWidget);

      await tester.tap(find.text('Add app rule'));
      await tester.pumpAndSettle();
      final dialog = find.byType(AlertDialog);
      await tester.enterText(find.descendant(of: dialog, matching: find.byType(TextField)).first, 'Test App');
      await tester.enterText(find.descendant(of: dialog, matching: find.byType(TextField)).last, 'com.test.app');
      await tester.tap(find.descendant(of: dialog, matching: find.text('Add')));
      await tester.pumpAndSettle();
      expect(find.text('com.test.app'), findsOneWidget);

      final gameCard = find.ancestor(of: find.text('com.example.game'), matching: find.byType(Card));
      await tester.tap(find.descendant(of: gameCard, matching: find.byIcon(Icons.delete_outline)));
      await tester.pumpAndSettle();
      expect(find.text('com.example.game'), findsNothing);
      expect(find.text('com.test.app'), findsOneWidget);
    });

    testWidgets('Save PUTs the full ruleset with all four sections', (tester) async {
      final api = FakeApiClient(standardRoutes());
      await pumpRules(tester, api);

      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      final puts = api.calls('PUT', '/v1/rules/child-1');
      expect(puts, hasLength(1));
      final body = puts.single.body;
      expect(body.keys, containsAll(['screenTime', 'webFilter', 'appRules', 'routines']));
      expect((body['screenTime'] as Map)['dailyLimitMinutes'], 120);
      expect(body['appRules'], hasLength(1));
      expect(body['routines'], hasLength(1));
      expect(find.text('Rules saved'), findsOneWidget);
    });
  });

  group('RulesEditorScreen — recommended protection (Feature #1)', () {
    Future<void> pumpWebFilter(WidgetTester tester, FakeApiClient api) async {
      await pumpScreen(tester, const RulesEditorScreen(childId: 'child-1'), api);
      await tester.tap(find.text('Web filter'));
      await tester.pumpAndSettle();
    }

    Finder recommendedSwitch() => find.widgetWithText(SwitchListTile, 'Recommended protection');

    /// Scrolls the lazy web-filter list until [finder]'s widget is built.
    Future<void> reveal(WidgetTester tester, Finder finder) async {
      await tester.scrollUntilVisible(finder, 150, scrollable: webFilterScrollable());
      await tester.pumpAndSettle();
    }

    Finder categoryTile(String category) => find.byKey(ValueKey('category-$category'));

    bool categoryChecked(WidgetTester tester, String category) =>
        tester.widget<CheckboxListTile>(categoryTile(category)).value!;

    testWidgets('switch is ON when all 13 recommended categories are blocked', (tester) async {
      final api = FakeApiClient(standardRoutes(blockedCategories: kRecommendedCategories));
      await pumpWebFilter(tester, api);

      expect(tester.widget<SwitchListTile>(recommendedSwitch()).value, isTrue);
      for (final c in kRecommendedCategories) {
        await reveal(tester, categoryTile(c));
        expect(categoryChecked(tester, c), isTrue, reason: '$c should be checked');
      }
    });

    testWidgets('turning OFF shows a confirm dialog, then unchecks all 13', (tester) async {
      final api = FakeApiClient(standardRoutes(blockedCategories: kRecommendedCategories));
      await pumpWebFilter(tester, api);
      expect(tester.widget<SwitchListTile>(recommendedSwitch()).value, isTrue);

      await tester.tap(recommendedSwitch());
      await tester.pumpAndSettle();
      expect(find.text('Disabling recommended categories reduces protection. Continue?'), findsOneWidget);

      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(recommendedSwitch()).value, isFalse);
      for (final c in kRecommendedCategories) {
        await reveal(tester, categoryTile(c));
        expect(categoryChecked(tester, c), isFalse, reason: '$c should be unchecked');
      }

      // The uncheck is part of the draft and is what gets saved.
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      final puts = api.calls('PUT', '/v1/rules/child-1');
      expect(puts, hasLength(1));
      expect((puts.single.body['webFilter'] as Map)['blockedCategories'], isEmpty);
    });

    testWidgets('cancel on the confirm dialog keeps all 13 checked', (tester) async {
      final api = FakeApiClient(standardRoutes(blockedCategories: kRecommendedCategories));
      await pumpWebFilter(tester, api);

      await tester.tap(recommendedSwitch());
      await tester.pumpAndSettle();
      expect(find.text('Disabling recommended categories reduces protection. Continue?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(tester.widget<SwitchListTile>(recommendedSwitch()).value, isTrue);
      for (final c in kRecommendedCategories) {
        await reveal(tester, categoryTile(c));
        expect(categoryChecked(tester, c), isTrue, reason: '$c should stay checked');
      }
      expect(api.calls('PUT', '/v1/rules/child-1'), isEmpty);
    });

    testWidgets('partial selection shows the switch OFF; turning ON checks all 13', (tester) async {
      final api = FakeApiClient(standardRoutes()); // default fixture blocks only 'pornography'
      await pumpWebFilter(tester, api);

      expect(tester.widget<SwitchListTile>(recommendedSwitch()).value, isFalse);
      expect(categoryChecked(tester, 'pornography'), isTrue);

      await tester.tap(recommendedSwitch());
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(recommendedSwitch()).value, isTrue);
      for (final c in kRecommendedCategories) {
        await reveal(tester, categoryTile(c));
        expect(categoryChecked(tester, c), isTrue, reason: '$c should be checked');
      }
    });
  });

  group('Layout robustness (320x568)', () {
    testWidgets('dashboard with long names does not overflow', (tester) async {
      final api = FakeApiClient(standardRoutes(
        familyMe: familyMeTwoChildren(
          alexName: 'Alexandra Maximiliana Featherstonehaugh',
          alexModel: 'Google Pixel 7a Prototype Ultra Wide Edition',
        ),
      ));
      await pumpScreen(tester, const DashboardScreen(), api, surface: const Size(320, 568));

      expect(find.text('Alexandra Maximiliana Featherstonehaugh'), findsOneWidget);
      final exceptions = drainExceptions(tester);
      expect(exceptions, isEmpty, reason: exceptions.join('\n'));
    });

    testWidgets('child detail with a long device model does not overflow', (tester) async {
      final api = FakeApiClient(standardRoutes(
        familyMe: familyMeTwoChildren(
          alexName: 'Alexandra Maximiliana Featherstonehaugh',
          alexModel: 'Samsung Galaxy S24 Ultra Enterprise Edition 5G',
        ),
      ));
      await pumpScreen(tester, const ChildDetailScreen(childId: 'child-1'), api, surface: const Size(320, 568));

      expect(find.text('Samsung Galaxy S24 Ultra Enterprise Edition 5G'), findsOneWidget);
      final exceptions = drainExceptions(tester);
      expect(exceptions, isEmpty, reason: exceptions.join('\n'));
    });
  });
}
