import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:familyshield_parent/api/models.dart';
import 'package:familyshield_parent/features/children/child_detail_screen.dart';
import 'package:familyshield_parent/l10n/l10n.dart';

/// #459: the child's alert list draws its titles through `AlertTile`, which has to pass the tamper alert's
/// `metadata.type` on. Without it the tile falls back to "Protection tampered with" and no other row notices.
void main() {
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
}
