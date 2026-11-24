import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:familyshield_parent/api/models.dart';
import 'package:familyshield_parent/features/children/child_detail_screen.dart';
import 'package:familyshield_parent/l10n/l10n.dart';

/// Issue #1050: a social scan alert carries the sender in `metadata.contact` and never the message text
/// (that stays in the vault, #24). Until this fix the generic tile drew only "category · time", so a flagged
/// message from a newly monitored contact looked like an alert with nothing in it.
///
/// Mutants these rows name: putting the social branch back behind `hasSocialCountSummary` reddens the first
/// two; dropping the `socialAlertUnknownContact` fallback reddens the third.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpTile(WidgetTester tester, Alert alert) => tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: AlertTile(alert: alert)),
        ),
      );

  Alert scanAlert({String? contact, DateTime? at}) => Alert(
        id: 'a-scan-1',
        childId: 'child-1',
        deviceId: 'dev-1',
        severity: 'warning',
        category: 'social_concern',
        title: 'Social concern in WhatsApp',
        body: '${contact ?? 'A contact'} sent a flagged message on WhatsApp',
        metadata: <String, dynamic>{
          'app': 'whatsapp',
          if (contact != null) 'contact': contact,
          'concernTypes': ['cyberbullying'],
        },
        createdAt: at ?? DateTime(2026, 11, 24, 9, 5),
        updatedAt: at ?? DateTime(2026, 11, 24, 9, 5),
      );

  testWidgets('a scan alert shows the sender and the time, not only the category', (tester) async {
    await pumpTile(tester, scanAlert(contact: 'Aisha Karim', at: DateTime(2026, 11, 24, 9, 15)));
    await tester.pumpAndSettle();

    final contact = tester.widget<Text>(find.byKey(const ValueKey('alert-contact-a-scan-1')));
    expect(contact.data, contains('Aisha Karim'));
    expect(find.byKey(const ValueKey('alert-latest-a-scan-1')), findsOneWidget);
    // The sender must not be the whole subtitle any more: category · time is the old, empty-looking row.
    expect(find.textContaining('Social concern ·'), findsNothing);
  });

  testWidgets('a scan alert with no contact falls back to the unknown-contact line', (tester) async {
    await pumpTile(tester, scanAlert(contact: null));
    await tester.pumpAndSettle();

    final l10n = AppLocalizations.of(
      tester.element(find.byKey(const ValueKey('alert-contact-a-scan-1'))),
    )!;
    final contact = tester.widget<Text>(find.byKey(const ValueKey('alert-contact-a-scan-1')));
    expect(contact.data, contains(l10n.socialAlertUnknownContact));
  });

  testWidgets('a non-social alert keeps the category line, not a sender line', (tester) async {
    await pumpTile(
      tester,
      Alert(
        id: 'a-blocked-1',
        childId: 'child-1',
        severity: 'info',
        category: 'app_blocked',
        title: 'Blocked app attempt',
        body: 'Attempted to open TikTok',
        metadata: const <String, dynamic>{},
        createdAt: DateTime(2026, 11, 24, 9, 20),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('alert-contact-a-blocked-1')), findsNothing);
    expect(find.textContaining('Blocked app'), findsOneWidget);
  });
}
