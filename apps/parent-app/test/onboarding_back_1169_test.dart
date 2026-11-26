import 'package:familyshield_parent/features/onboarding/setup_child_screen.dart';
import 'package:familyshield_parent/features/onboarding/setup_done_screen.dart';
import 'package:familyshield_parent/features/onboarding/setup_monitoring_screen.dart';
import 'package:familyshield_parent/features/onboarding/setup_pair_screen.dart';
import 'package:familyshield_parent/l10n/app_localizations.dart';
import 'package:familyshield_parent/providers/auth_provider.dart';
import 'package:familyshield_parent/providers/onboarding_provider.dart';
import 'package:familyshield_parent/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_api_client.dart';

/// #1169 regression tests:
/// Pressing Android system Back (`handlePopRoute()`) from any onboarding route for a
/// signed-in parent who already has children navigates to the previous onboarding step
/// or Home (`/`), and NEVER triggers `SystemNavigator.pop`.
///
/// Mutant: removing `PopScope(canPop: false, ...)` from any of `SetupChildScreen`,
/// `SetupPairScreen`, `SetupMonitoringScreen`, or `SetupDoneScreen` causes
/// `SystemNavigator.pop` to be called (`systemPopCount > 0`) and fails the test.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  int systemPopCount = 0;

  setUp(() {
    systemPopCount = 0;
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({
      kOnboardingCompleteKey: false,
      kOnboardingStepKey: 'add_child',
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'SystemNavigator.pop') {
        systemPopCount += 1;
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  GoRouter buildTestRouter({required String initialLocation}) => GoRouter(
        initialLocation: initialLocation,
        routes: [
          GoRoute(
            path: '/',
            builder: (_, __) => const Scaffold(
              body: Center(child: Text('HOME_SENTINEL', key: ValueKey('homeSentinel'))),
            ),
          ),
          GoRoute(
            path: '/setup/child',
            builder: (_, __) => const SetupChildScreen(),
          ),
          GoRoute(
            path: '/setup/pair',
            builder: (_, __) => const SetupPairScreen(),
          ),
          GoRoute(
            path: '/setup/monitoring',
            builder: (_, state) => SetupMonitoringScreen(
              childId: state.uri.queryParameters['childId'],
            ),
          ),
          GoRoute(
            path: '/setup/done',
            builder: (_, __) => const SetupDoneScreen(),
          ),
        ],
      );

  FakeApiClient existingChildApi() => FakeApiClient({
        ...standardRoutes(),
        'POST /v1/devices/pair/start': (_) => {
              'code': '123456',
              'expiresAt': DateTime.now()
                  .toUtc()
                  .add(const Duration(minutes: 10))
                  .toIso8601String(),
            },
      });

  Future<void> pumpAt(
    WidgetTester tester,
    GoRouter router,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(existingChildApi()),
        ],
        child: MaterialApp.router(
          theme: AppTheme.light,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          routerConfig: router,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    '#1169: system Back from /setup/child (signed-in parent with existing children) goes to Home, never SystemNavigator.pop',
    (tester) async {
      final router = buildTestRouter(initialLocation: '/setup/child');
      await pumpAt(tester, router);

      expect(find.byKey(const ValueKey('onboardingExistingContinue')), findsOneWidget);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(systemPopCount, 0);
      expect(find.byKey(const ValueKey('homeSentinel')), findsOneWidget);
    },
  );

  testWidgets(
    '#1169: system Back from /setup/pair goes to /setup/child, then Back again goes to Home (never SystemNavigator.pop)',
    (tester) async {
      final router = buildTestRouter(initialLocation: '/setup/pair');
      await pumpAt(tester, router);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(systemPopCount, 0);
      expect(find.byKey(const ValueKey('onboardingExistingContinue')), findsOneWidget);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(systemPopCount, 0);
      expect(find.byKey(const ValueKey('homeSentinel')), findsOneWidget);
    },
  );

  testWidgets(
    '#1169: system Back from /setup/monitoring and /setup/done goes to /setup/pair, never SystemNavigator.pop',
    (tester) async {
      final router = buildTestRouter(initialLocation: '/setup/monitoring?childId=child-1');
      await pumpAt(tester, router);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(systemPopCount, 0);
      expect(router.routerDelegate.currentConfiguration.uri.path, '/setup/pair');

      router.go('/setup/done');
      await tester.pumpAndSettle();

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(systemPopCount, 0);
      expect(router.routerDelegate.currentConfiguration.uri.path, '/setup/pair');
    },
  );
}
