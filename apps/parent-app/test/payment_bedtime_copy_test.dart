import 'package:familyshield_parent/features/rules/rules_editor_screen.dart';
import 'package:familyshield_parent/l10n/app_localizations_ar.dart';
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

  /// Claude's #486 review: with only Google's wallet in the child's inventory, the shortcut must offer
  /// that name — prefilling Samsung's on a Pixel offers a package that is not installed.
  testWidgets('the shortcut prefills the first suggestion the child actually has', (tester) async {
    final api = FakeApiClient({
      ...standardRoutes(),
      'GET /v1/devices/dev-1/apps': (_) => installedAppsPayload(
            apps: [installedAppJson('com.google.android.apps.walletnfcrel', 'Wallet')],
          ),
    });
    await tester.pumpWidget(ProviderScope(
      overrides: [apiClientProvider.overrideWithValue(api)],
      child: localizedTestApp(const RulesEditorScreen(childId: 'child-1')),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Apps'));
    await tester.pumpAndSettle();
    await tester.drag(find.byKey(const ValueKey('appsRulesList')), const Offset(0, -80));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('add-payment-app')));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    final field = tester.widget<TextField>(
      find.descendant(of: find.byType(AlertDialog), matching: find.byType(TextField)),
    );
    expect(field.controller?.text, 'com.google.android.apps.walletnfcrel');
  });

  /// Karim's approved Arabic, pinned as literals (#486 review). If a generator, a merge or a well-meaning
  /// edit changes either line, this fails instead of shipping wording he did not approve.
  test('the approved Arabic is pinned verbatim', () {
    final ar = AppLocalizationsAr();
    expect(ar.addPaymentApp, 'إضافة تطبيق دفع');
    expect(
      ar.bedtimeBlocksPayments,
      'يحجب وقت النوم أيضًا تطبيقات الدفع مثل Samsung Pay أو Google Wallet. '
      'إذا كانت عائلتك تحتاج أحدها ليلًا، فأضفه إلى «مسموح دائمًا» أدناه.',
    );
  });
}
