import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'features/auth/login_screen.dart';
import 'features/dashboard/dashboard_screen.dart';
import 'features/children/child_detail_screen.dart';
import 'features/children/command_history_screen.dart';
import 'features/alerts/alerts_screen.dart';
import 'features/family/family_screen.dart';
import 'features/map/family_map_screen.dart';
import 'features/onboarding/setup_child_screen.dart';
import 'features/onboarding/setup_done_screen.dart';
import 'features/onboarding/setup_pair_screen.dart';
import 'features/onboarding/startup_screen.dart';
import 'features/onboarding/welcome_screen.dart';
import 'features/pairing/pair_qr_screen.dart';
import 'features/reports/reports_screen.dart';
import 'features/reports/usage_history_screen.dart';
import 'features/rules/rules_editor_screen.dart';
import 'features/settings/appearance_screen.dart';
import 'features/settings/digest_prefs_screen.dart';
import 'features/settings/mfa_settings_screen.dart';
import 'features/social/social_screen.dart';
import 'features/content/search_safety_screen.dart';
import 'l10n/l10n.dart';
import 'providers/auth_provider.dart';
import 'providers/locale_provider.dart';
import 'providers/onboarding_provider.dart';
import 'providers/theme_provider.dart';
import 'theme/app_theme.dart';

const _setupRoutes = {'/welcome', '/sign-in', '/setup/child', '/setup/pair', '/setup/done'};

bool _isSetupRoute(String location) => _setupRoutes.contains(location);

final router = GoRouter(
  initialLocation: '/starting',
  refreshListenable: Listenable.merge([authRouterListenable, onboardingRouterListenable]),
  redirect: (context, state) {
    final container = ProviderScope.containerOf(context);
    final auth = container.read(authProvider);
    final onboarding = container.read(onboardingProvider);
    final location = state.matchedLocation;
    final setupRoute = _isSetupRoute(location);

    // Both persisted reads are asynchronous. Hold the neutral frame until they
    // answer, so a fresh install never flashes Login and a resumed wizard never
    // flashes the wrong step.
    if (!onboarding.loaded || auth.restoring) {
      return location == '/starting' ? null : '/starting';
    }

    if (onboarding.complete) {
      // A completed setup never shows the wizard again, even if the flag and
      // a stale step were both written by an older build.
      if (setupRoute || location == '/starting') return auth.isAuthenticated ? '/' : '/login';
      if (!auth.isAuthenticated && location != '/login') return '/login';
      if (auth.isAuthenticated && location == '/login') return '/';
      return null;
    }

    if (!auth.isAuthenticated) {
      // Sign-in cannot be skipped: every unauthenticated location resolves to
      // either Welcome (fresh) or the account step (a resume that lost its
      // session).
      if (location == '/sign-in') return null;
      return onboarding.step == OnboardingStep.none ? '/welcome' : '/sign-in';
    }

    if (onboarding.step == OnboardingStep.none) {
      // A signed-in account that predates the wizard is not forced through it.
      if (setupRoute || location == '/login' || location == '/starting') return '/';
      return null;
    }

    final target = switch (onboarding.step) {
      OnboardingStep.welcome || OnboardingStep.signIn || OnboardingStep.addChild => '/setup/child',
      OnboardingStep.pair => '/setup/pair',
      OnboardingStep.done => '/setup/done',
      OnboardingStep.none => '/',
    };
    // While the flow is in progress, every route belongs to the wizard: a
    // half-set-up account must not be left on the dashboard.
    return location == target ? null : target;
  },
  routes: [
    GoRoute(path: '/starting', builder: (_, __) => const StartupScreen()),
    GoRoute(path: '/welcome', builder: (_, __) => const WelcomeScreen()),
    GoRoute(path: '/sign-in', builder: (_, __) => const LoginScreen(onboarding: true)),
    GoRoute(path: '/setup/child', builder: (_, __) => const SetupChildScreen()),
    GoRoute(path: '/setup/pair', builder: (_, __) => const SetupPairScreen()),
    GoRoute(path: '/setup/done', builder: (_, __) => const SetupDoneScreen()),
    GoRoute(path: '/login', builder: (_, __) => const LoginScreen()),
    GoRoute(path: '/', builder: (_, __) => const DashboardScreen()),
    GoRoute(path: '/child/:id', builder: (_, s) => ChildDetailScreen(childId: s.pathParameters['id']!)),
    GoRoute(path: '/child/:id/pair', builder: (_, s) => PairingQrScreen(childId: s.pathParameters['id']!)),
    GoRoute(path: '/child/:id/commands', builder: (_, s) => CommandHistoryScreen(childId: s.pathParameters['id']!)),
    GoRoute(path: '/child/:id/reports', builder: (_, s) => ReportsScreen(childId: s.pathParameters['id']!)),
    GoRoute(path: '/child/:id/history', builder: (_, s) => UsageHistoryScreen(childId: s.pathParameters['id']!)),
    GoRoute(path: '/child/:id/rules', builder: (_, s) => RulesEditorScreen(childId: s.pathParameters['id']!)),
    GoRoute(path: '/child/:id/social', builder: (_, s) => SocialScreen(childId: s.pathParameters['id']!)),
    GoRoute(path: '/child/:id/searches', builder: (_, s) => SearchSafetyScreen(childId: s.pathParameters['id']!)),
    GoRoute(path: '/settings/digests', builder: (_, __) => const DigestPrefsScreen()),
    GoRoute(path: '/settings/appearance', builder: (_, __) => const AppearanceScreen()),
    GoRoute(path: '/settings/mfa', builder: (_, __) => const MfaSettingsScreen()),
    GoRoute(path: '/alerts', builder: (_, __) => const AlertsScreen()),
    GoRoute(path: '/map', builder: (_, __) => const FamilyMapScreen()),
    GoRoute(path: '/family', builder: (_, __) => const FamilyScreen()),
  ],
);

class FamilyShieldApp extends ConsumerWidget {
  const FamilyShieldApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(themeModeProvider);
    final locale = ref.watch(localeProvider);
    return MaterialApp.router(
      title: 'OSRA',
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      // ThemeMode.system follows MediaQuery.platformBrightness; Settings can
      // pin light or dark (persisted in shared_preferences).
      themeMode: mode,
      // A null locale follows the device; Appearance can pin English or
      // Arabic (persisted under the `app_locale` key).
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      routerConfig: router,
    );
  }
}
