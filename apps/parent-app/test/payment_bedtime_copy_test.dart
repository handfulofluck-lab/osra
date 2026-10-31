import 'package:familyshield_parent/features/rules/rules_editor_screen.dart';
import 'package:familyshield_parent/providers/auth_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_api_client.dart';
import 'test_app.dart';

/// Issue #172 / ADR-0035: payment surfaces stay blocked at bedtime, and the parent is told so **beside
/// the control that fixes it**. Mutants: delete the sentence → the first row; open the shortcut dialog
/// empty instead of prefilled → the second.
void main() {
  Future<void> pumpEditor(WidgetTester tester) async {
    final api = FakeApiClient(standardRoutes());
    await tester.pumpWidget(ProviderScope(
      overrides: [apiClientProvider.overrideWithValue(api)],
      child: localizedTestApp(const RulesEditorScreen(childId: 'child-1')),
    ));
    await tester.pumpAndSettle();
    // The always-allowed section lives on the Apps tab (`_buildApps`).
    await tester.tap(find.text('Apps'));
    await tester.pumpAndSettle();
    expect(find.text('Always allowed'), findsOneWidget);
  }

  testWidgets('the rule says bedtime blocks payment apps, next to the control that lifts it', (tester) async {
    await pumpEditor(tester);
    final note = find.byKey(const ValueKey('bedtime-blocks-payments'));
    expect(note, findsOneWidget);
    expect(find.textContaining('Samsung Pay'), findsWidgets);
    // The shortcut is present, and it is the *shortcut* — a parent should not have to look a package up.
    expect(find.byKey(const ValueKey('add-payment-app')), findsOneWidget);
  });

  testWidgets('the payment shortcut opens the add dialog prefilled with the first suggestion', (tester) async {
    await pumpEditor(tester);
    await tester.tap(find.byKey(const ValueKey('add-payment-app')));
    await tester.pumpAndSettle();
    expect(find.text(walletSuggestions.first), findsOneWidget);
  });
}
