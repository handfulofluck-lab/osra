import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:familyshield_parent/api/models.dart';
import 'package:familyshield_parent/app.dart' show appRoutes;
import 'package:familyshield_parent/features/alerts/alert_detail_screen.dart';
import 'package:familyshield_parent/features/alerts/alerts_screen.dart';
import 'package:familyshield_parent/features/dashboard/dashboard_screen.dart';
import 'package:familyshield_parent/l10n/l10n.dart';
import 'package:familyshield_parent/providers/auth_provider.dart';

import 'fake_api_client.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('direct Alerts entry returns to Dashboard on system Back',
      (tester) async {
    final router = GoRouter(initialLocation: '/alerts', routes: appRoutes);
    addTearDown(router.dispose);

    await tester.pumpWidget(ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(FakeApiClient(standardRoutes())),
      ],
      child: MaterialApp.router(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        routerConfig: router,
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.byType(AlertsScreen), findsOneWidget);
    expect(find.byType(DashboardScreen), findsNothing);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(find.byType(DashboardScreen), findsOneWidget);
    expect(find.byType(AlertsScreen), findsNothing);
  });

  testWidgets(
      'direct Alert detail entry returns to Alerts then Dashboard on system Back',
      (tester) async {
    const alert = Alert(
      id: 'alert-1',
      childId: 'child-1',
      severity: 'critical',
      category: 'sos',
      title: 'SOS',
      body: 'Synthetic alert',
    );
    final router = GoRouter(
      initialLocation: '/alerts/alert-1',
      initialExtra: alert,
      routes: appRoutes,
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(FakeApiClient(standardRoutes())),
      ],
      child: MaterialApp.router(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        routerConfig: router,
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDetailScreen), findsOneWidget);
    expect(find.byType(AlertsScreen), findsNothing);
    expect(find.byType(DashboardScreen), findsNothing);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(find.byType(AlertsScreen), findsOneWidget);
    expect(find.byType(AlertDetailScreen), findsNothing);
    expect(find.byType(DashboardScreen), findsNothing);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(find.byType(DashboardScreen), findsOneWidget);
    expect(find.byType(AlertsScreen), findsNothing);
    expect(find.byType(AlertDetailScreen), findsNothing);
  });
}
