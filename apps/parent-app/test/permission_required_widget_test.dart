import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:familyshield_parent/features/alerts/alerts_screen.dart';
import 'package:familyshield_parent/l10n/app_localizations.dart';
import 'package:familyshield_parent/providers/auth_provider.dart';
import 'fake_api_client.dart';

/// ADR-0014 amendment, decision 7 (and Claude's review of #405): the alerts screen must name the
/// refusal, and a real failure must still look like a failure.
///
/// These are the rows that make the branch load-bearing: without the first, deleting the new branch in
/// `alerts_screen.dart` stays green.

Future<void> pumpAlerts(WidgetTester tester, FakeApiClient api) async {
  await tester.pumpWidget(ProviderScope(
    overrides: [apiClientProvider.overrideWithValue(api)],
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('en'),
      home: const AlertsScreen(),
    ),
  ));
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  testWidgets('a refused alerts read names the owner, not "failed to load"', (tester) async {
    final api = FakeApiClient({
      'GET /v1/alerts': (_) => FakeHttpError(
            403,
            {'error': 'permission_required', 'permission': 'alerts'},
          ),
    });

    await pumpAlerts(tester, api);

    final l10n = lookupAppLocalizations(const Locale('en'));
    expect(find.text(l10n.readPermissionRequired), findsOneWidget);
    expect(find.textContaining('Failed to load alerts'), findsNothing);
  });

  testWidgets('a server error still shows the generic failure', (tester) async {
    final api = FakeApiClient({
      'GET /v1/alerts': (_) => FakeHttpError(500, {'error': 'internal'}),
    });

    await pumpAlerts(tester, api);

    final l10n = lookupAppLocalizations(const Locale('en'));
    expect(find.textContaining('Failed to load alerts'), findsOneWidget);
    expect(find.text(l10n.readPermissionRequired), findsNothing);
  });
}
