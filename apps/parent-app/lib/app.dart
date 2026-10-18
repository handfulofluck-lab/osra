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
import 'features/reports/reports_screen.dart';
import 'features/reports/usage_history_screen.dart';
import 'features/rules/rules_editor_screen.dart';
import 'features/settings/digest_prefs_screen.dart';
import 'features/social/social_screen.dart';
import 'features/content/search_safety_screen.dart';
import 'providers/auth_provider.dart';

final router = GoRouter(
  initialLocation: '/login',
  refreshListenable: authRouterListenable,
  redirect: (context, state) {
    final auth = ProviderScope.containerOf(context).read(authProvider);
    if (!auth.isAuthenticated && state.matchedLocation != '/login') return '/login';
    if (auth.isAuthenticated && state.matchedLocation == '/login') return '/';
    return null;
  },
  routes: [
    GoRoute(path: '/login', builder: (_, __) => const LoginScreen()),
    GoRoute(path: '/', builder: (_, __) => const DashboardScreen()),
    GoRoute(path: '/child/:id', builder: (_, s) => ChildDetailScreen(childId: s.pathParameters['id']!)),
    GoRoute(path: '/child/:id/commands', builder: (_, s) => CommandHistoryScreen(childId: s.pathParameters['id']!)),
    GoRoute(path: '/child/:id/reports', builder: (_, s) => ReportsScreen(childId: s.pathParameters['id']!)),
    GoRoute(path: '/child/:id/history', builder: (_, s) => UsageHistoryScreen(childId: s.pathParameters['id']!)),
    GoRoute(path: '/child/:id/rules', builder: (_, s) => RulesEditorScreen(childId: s.pathParameters['id']!)),
    GoRoute(path: '/child/:id/social', builder: (_, s) => SocialScreen(childId: s.pathParameters['id']!)),
    GoRoute(path: '/child/:id/searches', builder: (_, s) => SearchSafetyScreen(childId: s.pathParameters['id']!)),
    GoRoute(path: '/settings/digests', builder: (_, __) => const DigestPrefsScreen()),
    GoRoute(path: '/alerts', builder: (_, __) => const AlertsScreen()),
    GoRoute(path: '/map', builder: (_, __) => const FamilyMapScreen()),
    GoRoute(path: '/family', builder: (_, __) => const FamilyScreen()),
  ],
);

class FamilyShieldApp extends StatelessWidget {
  const FamilyShieldApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp.router(
        title: 'OSRA',
        theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
        routerConfig: router,
      );
}
