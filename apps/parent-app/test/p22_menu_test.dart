import 'package:familyshield_parent/features/dashboard/dashboard_screen.dart';
import 'package:familyshield_parent/features/settings/settings_screen.dart';
import 'package:go_router/go_router.dart';
import 'package:familyshield_parent/l10n/app_localizations.dart';
import 'package:familyshield_parent/providers/auth_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_api_client.dart';

/// P-22 reachability (Claude, 10:12 UAE): with `OSRA_UX_P22` on, the dashboard menu carries one **Settings**
/// entry; with it off, the four links this menu shipped with stay exactly as they were. Without this the
/// grouped screen exists and nothing reaches it, so the flag gates nothing.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  Future<GoRouter> pump(WidgetTester tester, {required bool uxP22}) async {
    final api = FakeApiClient(standardRoutes());
    final router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(path: '/', builder: (_, __) => const DashboardScreen()),
        GoRoute(path: '/settings', builder: (_, __) => const SettingsScreen()),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        p22SettingsEnabledProvider.overrideWithValue(uxP22),
      ],
      child: MaterialApp.router(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        routerConfig: router,
      ),
    ));
    await tester.pumpAndSettle();
    return router;
  }

  Future<void> openMenu(WidgetTester tester) async {
    await tester.tap(find.byType(PopupMenuButton<String>).first);
    await tester.pumpAndSettle();
  }

  /// Every assertion about the menu is scoped to the popup: the dashboard underneath carries these words too,
  /// so an unscoped `find.text` would answer a different question than the one being asked.
  Finder inMenu(String label) => find.descendant(
        of: find.byType(PopupMenuItem<String>),
        matching: find.text(label),
      );

  /// Exactly the four links this menu shipped with, in the order the flag-off menu must keep them.
  const shipped = ['Appearance', 'Digest preferences', 'Two-step verification', 'Delete account'];

  testWidgets('with the flag on the menu offers one Settings entry and none of the four', (tester) async {
    await pump(tester, uxP22: true);
    await openMenu(tester);

    expect(inMenu('Settings'), findsOneWidget);
    for (final label in shipped) {
      expect(inMenu(label), findsNothing, reason: 'flag on: "$label" is replaced by Settings');
    }
    await tester.tap(find.byKey(const ValueKey('dashboardMenu-settings')));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsScreen), findsOneWidget,
        reason: 'flag on: the menu entry must actually reach /settings');
  });

  testWidgets('with the flag off the four shipped links are unchanged', (tester) async {
    await pump(tester, uxP22: false);
    await openMenu(tester);

    expect(inMenu('Settings'), findsNothing);
    for (final label in shipped) {
      expect(inMenu(label), findsOneWidget, reason: 'flag off: "$label" still ships');
    }
  });
}
