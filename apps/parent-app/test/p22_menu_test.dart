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

  testWidgets('with the flag on the menu offers one Settings entry', (tester) async {
    await pump(tester, uxP22: true);
    await openMenu(tester);

    expect(find.byKey(const ValueKey('dashboardMenu-settings')), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('dashboardMenu-settings')));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsScreen), findsOneWidget,
        reason: 'flag on: the menu entry must actually reach /settings');
    // The four links it replaces are gone.
    expect(find.text('Appearance'), findsNothing);
    expect(find.text('Digest preferences'), findsNothing);
  });

  testWidgets('with the flag off the four shipped links are unchanged', (tester) async {
    await pump(tester, uxP22: false);
    await openMenu(tester);

    expect(find.byKey(const ValueKey('dashboardMenu-settings')), findsNothing);
    expect(find.text('Appearance'), findsOneWidget);
    expect(find.text('Digest preferences'), findsOneWidget);
    expect(find.text('Two-step verification'), findsOneWidget);
    expect(find.text('Delete account'), findsOneWidget);
  });
}
