import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:familyshield_parent/api/models.dart';
import 'package:familyshield_parent/features/alerts/alerts_screen.dart';
import 'package:familyshield_parent/features/children/child_detail_screen.dart';
import 'package:familyshield_parent/l10n/l10n.dart';
import 'package:familyshield_parent/providers/auth_provider.dart';
import 'fake_api_client.dart';
import 'test_app.dart';

/// #459: both places that draw a single alert's title have to pass the tamper alert's `metadata.type` on: the
/// child's alert list (`AlertTile`) and the alert dialog in the alerts feed. Without it they fall back to
/// "Protection tampered with", and no other row notices.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  Future<void> pumpTile(WidgetTester tester, Alert alert) => tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: AlertTile(alert: alert)),
        ),
      );

  Alert tamper(Map<String, dynamic> metadata) => Alert(
        id: 'a-1',
        childId: 'child-1',
        severity: 'critical',
        category: 'tamper',
        title: 'A blocked app stayed on screen',
        body: 'body',
        metadata: metadata,
      );

  testWidgets('AlertTile titles a block_bypass tamper alert by its type', (tester) async {
    await pumpTile(tester, tamper({'type': 'block_bypass', 'app': 'com.example', 'layout': 'call'}));
    await tester.pumpAndSettle();
    expect(find.text('An app got around the block'), findsOneWidget);
    expect(find.text('Protection tampered with'), findsNothing);
  });

  testWidgets('AlertTile keeps the generic tamper title for any other type', (tester) async {
    await pumpTile(tester, tamper({'type': 'protection_screen_opened'}));
    await tester.pumpAndSettle();
    expect(find.text('Protection tampered with'), findsOneWidget);
  });

  testWidgets('the alert dialog in the feed titles a block_bypass tamper alert by its type', (tester) async {
    final alert = alertJson('t1', 'critical', 'tamper', 'A blocked app stayed on screen', DateTime.now())
      ..['metadata'] = <String, dynamic>{'type': 'block_bypass', 'app': 'com.example', 'layout': 'picture_in_picture'};
    final api = FakeApiClient(standardRoutes(alerts: [alert]));
    await tester.pumpWidget(ProviderScope(
      overrides: [apiClientProvider.overrideWithValue(api)],
      child: localizedTestApp(const AlertsScreen()),
    ));
    await tester.pumpAndSettle();
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.tap(find.text('An app got around the block').first);
    await tester.pumpAndSettle();

    final inDialog = find.descendant(of: find.byType(AlertDialog), matching: find.text('An app got around the block'));
    expect(inDialog, findsOneWidget);
    expect(find.descendant(of: find.byType(AlertDialog), matching: find.text('Protection tampered with')), findsNothing);
  });
}
