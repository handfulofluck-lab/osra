import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:familyshield_parent/app.dart';
import 'package:familyshield_parent/features/auth/login_screen.dart';
import 'package:familyshield_parent/features/dashboard/dashboard_screen.dart';
import 'package:familyshield_parent/features/onboarding/setup_child_screen.dart';
import 'package:familyshield_parent/features/onboarding/setup_done_screen.dart';
import 'package:familyshield_parent/features/onboarding/setup_pair_screen.dart';
import 'package:familyshield_parent/features/onboarding/welcome_screen.dart';
import 'package:familyshield_parent/features/pairing/pair_qr_screen.dart';
import 'package:familyshield_parent/providers/auth_provider.dart';
import 'package:familyshield_parent/providers/onboarding_provider.dart';
import 'package:familyshield_parent/providers/server_provider.dart';

import 'fake_api_client.dart';
import 'test_app.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  Map<String, dynamic> parentJson() => {
        'id': 'par-1',
        'familyId': 'fam-1',
        'email': 'qa@familyshield.dev',
        'displayName': 'QA Parent',
        'role': 'owner',
        'mfaEnabled': false,
      };

  Map<String, dynamic> childJson(String id, String name) => {
        'id': id,
        'familyId': 'fam-1',
        'displayName': name,
        'birthYear': 2014,
        'screenTimeTodayMinutes': 0,
      };

  Map<String, dynamic> deviceJson(String id, String childId) => {
        'id': id,
        'childId': childId,
        'platform': 'android',
        'model': 'Pixel 7a',
        'osVersion': '14',
        'status': 'online',
        'batteryPct': 80,
        'lastSeen': DateTime.now().toUtc().toIso8601String(),
      };

  /// A stateful family route: the wizard's POSTs mutate these lists, so the
  /// screens see what a real server would report after each step.
  Map<String, FakeRoute> onboardingRoutes({
    required List<Map<String, dynamic>> children,
    required List<Map<String, dynamic>> devices,
    FakeRoute? addChild,
    FakeRoute? pair,
    DateTime? pairExpiry,
  }) {
    return {
      ...standardRoutes(),
      'GET /v1/family/me': (_) => {
            'family': {'id': 'fam-1', 'name': 'QA Family', 'region': 'US'},
            'parent': parentJson(),
            'parents': [parentJson()],
            'children': children,
            'devices': devices,
          },
      'POST /v1/family/children': addChild ??
          (req) {
            final child = childJson('child-new', req.body['displayName'] as String? ?? 'Child');
            children.add(child);
            return {
              'child': child,
              'consent': {'id': 'consent-1'},
            };
          },
      'POST /v1/devices/pair': pair ??
          (_) => {
                'code': '482916',
                'expiresAt': (pairExpiry ?? DateTime.now().toUtc().add(const Duration(minutes: 10)))
                    .toIso8601String(),
              },
    };
  }

  /// Lets a fake-Dio request chain and the prefs/auth futures complete.
  Future<void> flush(WidgetTester tester, {int frames = 20}) async {
    for (var i = 0; i < frames; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> pumpApp(WidgetTester tester, FakeApiClient api) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [apiClientProvider.overrideWithValue(api)],
      child: const FamilyShieldApp(),
    ));
    await flush(tester);
  }

  /// The pairing screen owns a 1 s countdown, so `pumpAndSettle` cannot be
  /// used while it is mounted. Use frames and unmount at the end of the test.
  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  }

  /// Pumps frames until [finder] matches (fake Dio chains complete through
  /// zero-duration timers, so one frame is not enough).
  Future<void> waitFor(WidgetTester tester, Finder finder, {int frames = 40}) async {
    for (var i = 0; i < frames; i++) {
      if (finder.evaluate().isNotEmpty) return;
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Finder fieldByLabel(String label) =>
      find.ancestor(of: find.text(label), matching: find.byType(TextField));

  String currentPath() => router.routerDelegate.currentConfiguration.uri.path;

  /// The global router keeps its last location between tests; start the flow
  /// at Welcome explicitly when the previous test left another route mounted.
  Future<void> startFromWelcome(WidgetTester tester) async {
    for (var attempt = 0; attempt < 5; attempt++) {
      if (find.byKey(const ValueKey('onboardingGetStarted')).evaluate().isNotEmpty) break;
      router.go('/welcome');
      await flush(tester, frames: 10);
    }
    expect(find.byKey(const ValueKey('onboardingGetStarted')), findsOneWidget,
        reason: 'the welcome step did not open (at ${currentPath()})');
    await tester.tap(find.byKey(const ValueKey('onboardingGetStarted')));
    await tester.pumpAndSettle();
  }

  /// Scrolls a lazily built ListView child into view (the pair step's primary
  /// action sits below the 800x600 test fold).
  Future<void> scrollTo(WidgetTester tester, Finder finder) async {
    if (finder.evaluate().isNotEmpty) {
      await tester.ensureVisible(finder);
      await tester.pump();
      return;
    }
    final scrollable = find.byWidgetPredicate((w) => w is Scrollable && w.axis == Axis.vertical);
    await tester.scrollUntilVisible(finder, 200, scrollable: scrollable.first);
    await tester.pump();
  }

  Future<void> signIn(WidgetTester tester, {String password = 'good-password'}) async {
    await tester.enterText(fieldByLabel('Server'), 'http://testserver');
    await tester.enterText(fieldByLabel('Email'), 'qa@familyshield.dev');
    await tester.enterText(fieldByLabel('Password'), password);
    final button = find.widgetWithText(FilledButton, 'Sign in');
    await tester.ensureVisible(button);
    await tester.pumpAndSettle();
    await tester.tap(button);
    await flush(tester);
  }

  List<Object> drainExceptions(WidgetTester tester) {
    final exceptions = <Object>[];
    while (true) {
      final e = tester.takeException();
      if (e == null) return exceptions;
      exceptions.add(e);
    }
  }

  group('first-run gating', () {
    testWidgets('a fresh install opens the welcome step, not the login screen', (tester) async {
      final api = FakeApiClient(onboardingRoutes(children: [], devices: []));
      SharedPreferences.setMockInitialValues({});
      await pumpApp(tester, api);
      await tester.pumpAndSettle();

      expect(find.byType(WelcomeScreen), findsOneWidget);
      expect(find.byType(LoginScreen), findsNothing);
      expect(currentPath(), '/welcome');
    });

    testWidgets('a completed setup never shows the wizard again', (tester) async {
      SharedPreferences.setMockInitialValues({kOnboardingCompleteKey: true});
      final api = FakeApiClient(onboardingRoutes(children: [], devices: []));
      await pumpApp(tester, api);
      await tester.pumpAndSettle();

      expect(find.byType(LoginScreen), findsOneWidget);
      expect(find.byType(WelcomeScreen), findsNothing);
      expect(currentPath(), '/login');
    });

    testWidgets('a completed setup with a stored session opens the dashboard', (tester) async {
      SharedPreferences.setMockInitialValues({kOnboardingCompleteKey: true});
      FlutterSecureStorage.setMockInitialValues({'jwt': 'jwt-token'});
      final api = FakeApiClient(onboardingRoutes(
        children: [childJson('child-1', 'Alex')],
        devices: [deviceJson('dev-1', 'child-1')],
      ));
      await pumpApp(tester, api);
      await tester.pumpAndSettle();

      expect(find.byType(DashboardScreen), findsOneWidget);
      expect(currentPath(), '/');
    });
  });

  testWidgets('sign-in cannot be skipped: a direct setup route lands on sign-in', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final api = FakeApiClient(onboardingRoutes(children: [], devices: []));
    await pumpApp(tester, api);
    await tester.pumpAndSettle();

    await startFromWelcome(tester);
    expect(find.byType(LoginScreen), findsOneWidget);
    expect(find.byType(SetupChildScreen), findsNothing);
    expect(currentPath(), '/sign-in');

    router.go('/setup/child');
    await tester.pumpAndSettle();
    expect(currentPath(), '/sign-in');
    expect(find.byType(LoginScreen), findsOneWidget);
    expect(find.byType(SetupChildScreen), findsNothing);
  });

  group('resume', () {
    testWidgets('an in-progress pair step reopens the same child', (tester) async {
      SharedPreferences.setMockInitialValues({
        kOnboardingCompleteKey: false,
        kOnboardingStepKey: 'pair',
        kOnboardingChildIdKey: 'child-1',
        kServerUrlKey: 'http://testserver',
      });
      FlutterSecureStorage.setMockInitialValues({'jwt': 'jwt-token'});
      final api = FakeApiClient(onboardingRoutes(
        children: [childJson('child-1', 'Alex')],
        devices: [],
      ));
      await pumpApp(tester, api);
      await flush(tester);

      expect(currentPath(), '/setup/pair');
      expect(find.byType(SetupPairScreen), findsOneWidget);
      await waitFor(tester, find.byType(PairingQrScreen));
      expect(find.byType(PairingQrScreen), findsOneWidget);
      expect(api.calls('POST', '/v1/devices/pair'), isNotEmpty,
          reason: 'the wizard pair step must request a code');
      await waitFor(tester, find.text('482916'));
      expect(find.text('482916'), findsOneWidget);
      await unmount(tester);
    });

    testWidgets('an in-progress child step reopens the form', (tester) async {
      SharedPreferences.setMockInitialValues({
        kOnboardingCompleteKey: false,
        kOnboardingStepKey: 'add_child',
      });
      FlutterSecureStorage.setMockInitialValues({'jwt': 'jwt-token'});
      final api = FakeApiClient(onboardingRoutes(children: [], devices: []));
      await pumpApp(tester, api);
      await tester.pumpAndSettle();

      expect(currentPath(), '/setup/child');
      expect(find.byType(SetupChildScreen), findsOneWidget);
      expect(find.byKey(const ValueKey('onboardingChildName')), findsOneWidget);
    });
  });

  testWidgets('skipping pairing leaves a persistent dashboard affordance', (tester) async {
    SharedPreferences.setMockInitialValues({
      kOnboardingCompleteKey: false,
      kOnboardingStepKey: 'pair',
      kOnboardingChildIdKey: 'child-1',
    });
    FlutterSecureStorage.setMockInitialValues({'jwt': 'jwt-token'});
    final api = FakeApiClient(onboardingRoutes(
      children: [childJson('child-1', 'Alex')],
      devices: [],
    ));
    await pumpApp(tester, api);
    await flush(tester);
    await waitFor(tester, find.byType(PairingQrScreen));

    expect(find.byType(PairingQrScreen), findsOneWidget);
    final skip = find.byKey(const ValueKey('onboardingPairSkip'));
    await scrollTo(tester, skip);
    await tester.tap(skip);
    await tester.pumpAndSettle();

    // The Done step is honest: no success copy while pairing is pending.
    expect(find.text('One step left'), findsOneWidget);
    expect(find.text("You're all set"), findsNothing);

    await tester.tap(find.byKey(const ValueKey('onboardingFinish')));
    await flush(tester);
    await waitFor(tester, find.byKey(const ValueKey('finishSetupBanner')));

    expect(find.byType(DashboardScreen), findsOneWidget);
    expect(find.byKey(const ValueKey('finishSetupBanner')), findsOneWidget);
    expect(find.text('Finish setting up'), findsOneWidget);
    expect(find.text('Pair now'), findsOneWidget);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(kOnboardingCompleteKey), isTrue);
    expect(prefs.getBool(kPairingPendingKey), isTrue);
    expect(prefs.getString(kOnboardingChildIdKey), 'child-1');

    await tester.tap(find.byKey(const ValueKey('finishSetupPairNow')));
    await waitFor(tester, find.byType(PairingQrScreen));
    expect(find.byType(PairingQrScreen), findsOneWidget);
    // `context.push` keeps the dashboard underneath, so the route stack is
    // asserted by the screen rather than by `currentConfiguration.uri`.
    await unmount(tester);
  });

  testWidgets('the full happy path reaches Done only after a confirmed device', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final children = <Map<String, dynamic>>[];
    final devices = <Map<String, dynamic>>[];
    final api = FakeApiClient(onboardingRoutes(children: children, devices: devices));

    await pumpApp(tester, api);
    await tester.pumpAndSettle();
    await startFromWelcome(tester);

    await signIn(tester);
    await tester.pumpAndSettle();
    expect(currentPath(), '/setup/child');
    expect(find.byKey(const ValueKey('onboardingChildName')), findsOneWidget);

    await tester.enterText(find.byKey(const ValueKey('onboardingChildName')), 'Alex');
    await tester.enterText(find.byKey(const ValueKey('onboardingBirthYear')), '2014');
    final add = find.byKey(const ValueKey('onboardingAddChild'));
    await tester.ensureVisible(add);
    await tester.pumpAndSettle();
    await tester.tap(add);
    await flush(tester);
    await waitFor(tester, find.text('482916'));

    expect(currentPath(), '/setup/pair');
    expect(find.byType(PairingQrScreen), findsOneWidget);
    expect(find.text('482916'), findsOneWidget);

    // Nothing claims the pairing yet: the primary action must not advance.
    final pairDone = find.byKey(const ValueKey('onboardingPairDone'));
    await scrollTo(tester, pairDone);
    await tester.tap(pairDone);
    await flush(tester);
    expect(currentPath(), '/setup/pair');
    expect(find.byKey(const ValueKey('onboardingPairWaiting')), findsOneWidget);

    // The child app claims the code; the next check sees the device.
    devices.add(deviceJson('dev-new', 'child-new'));
    await scrollTo(tester, pairDone);
    await tester.tap(pairDone);
    await flush(tester);
    await tester.pumpAndSettle();

    expect(currentPath(), '/setup/done');
    expect(find.text("You're all set"), findsOneWidget);
    expect(find.byKey(const ValueKey('onboardingDoneTitle')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('onboardingFinish')));
    await flush(tester);
    expect(find.byType(DashboardScreen), findsOneWidget);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(kOnboardingCompleteKey), isTrue);
    expect(prefs.getBool(kPairingPendingKey), isFalse);
  });

  group('honest failure states', () {
    testWidgets('a wrong password says what to check, not the API code', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final api = FakeApiClient(onboardingRoutes(children: [], devices: []));
      await pumpApp(tester, api);
      await tester.pumpAndSettle();
      await startFromWelcome(tester);

      await signIn(tester, password: 'wrong-password');
      await tester.pumpAndSettle();

      expect(find.text('The email or password is incorrect. Check it and try again.'), findsOneWidget);
      expect(find.text('invalid_credentials'), findsNothing);
    });

    testWidgets('an unreachable server says so', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final routes = onboardingRoutes(children: [], devices: []);
      routes['POST /v1/auth/login'] = (_) => const FakeNetworkError();
      final api = FakeApiClient(routes);
      await pumpApp(tester, api);
      await tester.pumpAndSettle();
      await startFromWelcome(tester);

      await signIn(tester);
      await tester.pumpAndSettle();

      expect(find.textContaining('Cannot reach the server'), findsOneWidget);
    });

    testWidgets('a child-creation refusal names the consent problem', (tester) async {
      SharedPreferences.setMockInitialValues({
        kOnboardingCompleteKey: false,
        kOnboardingStepKey: 'add_child',
      });
      FlutterSecureStorage.setMockInitialValues({'jwt': 'jwt-token'});
      final routes = onboardingRoutes(
        children: [],
        devices: [],
        addChild: (_) => const FakeHttpError(428, {'error': 'parental_consent_required'}),
      );
      final api = FakeApiClient(routes);
      await pumpApp(tester, api);
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(const ValueKey('onboardingChildName')), 'Alex');
      await tester.enterText(find.byKey(const ValueKey('onboardingBirthYear')), '2014');
      final add = find.byKey(const ValueKey('onboardingAddChild'));
      await tester.ensureVisible(add);
      await tester.pumpAndSettle();
      await tester.tap(add);
      await flush(tester);

      expect(find.textContaining('needs parental consent'), findsOneWidget);
      expect(currentPath(), '/setup/child');
    });

    testWidgets('an expired pairing code disables Continue and offers a new code', (tester) async {
      SharedPreferences.setMockInitialValues({
        kOnboardingCompleteKey: false,
        kOnboardingStepKey: 'pair',
        kOnboardingChildIdKey: 'child-1',
        kServerUrlKey: 'http://testserver',
      });
      FlutterSecureStorage.setMockInitialValues({'jwt': 'jwt-token'});
      final api = FakeApiClient(onboardingRoutes(
        children: [childJson('child-1', 'Alex')],
        devices: [],
        pairExpiry: DateTime.now().toUtc().subtract(const Duration(seconds: 1)),
      ));
      await pumpApp(tester, api);
      await flush(tester);
      await waitFor(tester, find.text('Code expired'));

      expect(find.text('Code expired'), findsOneWidget);
      final done = tester.widget<FilledButton>(find.byKey(const ValueKey('onboardingPairDone')));
      expect(done.onPressed, isNull);
      expect(find.byKey(const ValueKey('onboardingPairSkip')), findsOneWidget);
      expect(find.text('Generate a new code to keep pairing.'), findsOneWidget);
      await unmount(tester);
    });
  });

  group('Arabic + RTL at 320x568 (every wizard step)', () {
    Future<void> pumpStep(WidgetTester tester, Widget home, FakeApiClient api,
        {bool settle = true}) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      await tester.pumpWidget(ProviderScope(
        overrides: [apiClientProvider.overrideWithValue(api)],
        child: localizedTestApp(
          home,
          locale: const Locale('ar'),
          textDirection: TextDirection.rtl,
        ),
      ));
      if (settle) {
        await tester.pumpAndSettle();
      } else {
        await flush(tester, frames: 12);
      }
    }

    void expectRtlAndNoOverflow(WidgetTester tester) {
      final scaffold = find.byType(Scaffold).first;
      expect(Directionality.of(tester.element(scaffold)), TextDirection.rtl);
      final exceptions = drainExceptions(tester);
      expect(
        exceptions,
        isEmpty,
        reason: exceptions.map((e) => e is FlutterError ? e.toStringDeep() : '$e').join('\n'),
      );
    }

    testWidgets('welcome', (tester) async {
      final api = FakeApiClient(onboardingRoutes(children: [], devices: []));
      await pumpStep(tester, const WelcomeScreen(), api);
      expect(find.text('مرحبًا بك في OSRA'), findsOneWidget);
      expectRtlAndNoOverflow(tester);
    });

    testWidgets('sign in / create account', (tester) async {
      final api = FakeApiClient(onboardingRoutes(children: [], devices: []));
      await pumpStep(tester, const LoginScreen(onboarding: true), api);
      expect(find.text('سجّل الدخول أو أنشئ حسابًا'), findsOneWidget);
      expectRtlAndNoOverflow(tester);
    });

    testWidgets('add your child', (tester) async {
      final api = FakeApiClient(onboardingRoutes(children: [], devices: []));
      await pumpStep(tester, const SetupChildScreen(), api);
      expect(find.text('أضف طفلك'), findsOneWidget);
      expectRtlAndNoOverflow(tester);
    });

    testWidgets('the consent notice speaks Arabic and names no law (#426)', (tester) async {
      // Roadmap 3.1's last half. The notice was deliberately English pending Karim's wording ("we need
      // to confirm that you are their parent or guardian", 2026-10-28 09:02Z), which also decided that
      // the law names leave the app — COPPA/GDPR-K belong in the privacy policy, not in a sentence a
      // parent reads before adding a child.
      //
      // The assertion is the Arabic LITERAL, not `l10n.consentNotice`: a row that compares the screen to
      // the getter that feeds it passes whatever the ARB says, which is the #429 lesson. Reverting the
      // value to the old English text turns this row red.
      final api = FakeApiClient(onboardingRoutes(children: [], devices: []));
      await pumpStep(tester, const SetupChildScreen(), api);
      expect(
        find.text('قبل إضافة طفل، نحتاج إلى التأكّد من أنك وليّ أمره.'),
        findsOneWidget,
        reason: 'the consent notice must be the approved Arabic, not the old English sentence',
      );
      expect(find.textContaining('COPPA'), findsNothing, reason: 'law names stay out of the app');
      expect(find.textContaining('Verifiable'), findsNothing, reason: 'no English notice text');
      expectRtlAndNoOverflow(tester);
    });

    testWidgets('pair their device', (tester) async {
      final api = FakeApiClient(onboardingRoutes(
        children: [childJson('child-1', 'Alex')],
        devices: [],
      ));
      await pumpStep(tester, const SetupPairScreen(), api, settle: false);
      expect(find.text('إقران جهاز'), findsOneWidget);
      expectRtlAndNoOverflow(tester);
      await unmount(tester);
    });

    testWidgets('done / one step left', (tester) async {
      SharedPreferences.setMockInitialValues({
        kOnboardingCompleteKey: false,
        kOnboardingStepKey: 'done',
        kOnboardingChildIdKey: 'child-1',
        kPairingPendingKey: true,
      });
      final api = FakeApiClient(onboardingRoutes(
        children: [childJson('child-1', 'Alex')],
        devices: [],
      ));
      await pumpStep(tester, const SetupDoneScreen(), api);
      expect(find.text('بقيت خطوة واحدة'), findsOneWidget);
      expectRtlAndNoOverflow(tester);
    });
  });

  group('ARB parity', () {
    Map<String, dynamic> readArb(String name) =>
        jsonDecode(File('lib/l10n/$name').readAsStringSync()) as Map<String, dynamic>;

    test('the wizard added the same keys to both locales', () {
      final en = readArb('app_en.arb');
      final ar = readArb('app_ar.arb');
      final wizardKeys = {
        for (final key in en.keys)
          if (!key.startsWith('@') && key.startsWith('onboarding')) key,
      };
      expect(wizardKeys, isNotEmpty);
      for (final key in wizardKeys) {
        expect(ar.containsKey(key), isTrue, reason: 'app_ar.arb is missing $key');
        expect((ar[key] as String?)?.trim(), isNotEmpty, reason: 'app_ar.arb has an empty $key');
      }
    });
  });
}
