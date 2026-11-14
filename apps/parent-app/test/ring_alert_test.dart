import 'package:familyshield_parent/api/models.dart';
import 'package:familyshield_parent/features/children/command_messages.dart';
import 'package:familyshield_parent/l10n/l10n.dart';
import 'package:familyshield_parent/l10n/app_localizations_en.dart';
import 'package:familyshield_parent/l10n/app_localizations_ar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:familyshield_parent/features/alerts/alerts_screen.dart';
import 'package:familyshield_parent/providers/auth_provider.dart';

import 'fake_api_client.dart';
import 'test_app.dart';

void main() {
  Alert ringAlert(String state, String bodyKey, Map<String, dynamic> params, String body) => Alert(
        id: 'a1', childId: 'c1', severity: state == 'child_dismissed' ? 'warning' : 'info',
        category: 'ring', title: 'Phone ring', body: body,
        metadata: {'bodyKey': bodyKey, 'bodyParams': params, 'state': state, 'ringId': 'ring-1'},
      );

  test('ring child dismissal uses bodyKey and count, not raw metadata', () {
    final alert = ringAlert('child_dismissed', 'alertBodyRingChildDismissed',
        {'ringId': 'ring-1', 'dismissalCount': 2}, 'English fallback');
    expect(alertBodyFor(alert, AppLocalizationsEn()), contains('2 times'));
    expect(alertBodyFor(alert, AppLocalizationsEn()), isNot(contains('state: child_dismissed')));
    expect(alertBodyFor(alert, AppLocalizationsEn()), isNot(contains('English fallback')));
  });

  test('every ring stop has its own localized body', () {
    final cases = {
      'alertBodyRingPinStopped': 'The ring was stopped on the phone with the parent PIN.',
      'alertBodyRingParentStopped': 'A parent stopped the ring from the OSRA app.',
      'alertBodyRingTimedOut': 'The ring ended by itself after 5 minutes.',
    };
    cases.forEach((key, sentence) {
      final alert = ringAlert('pin_stopped', key, {'ringId': 'ring-1'}, 'English fallback');
      expect(alertBodyFor(alert, AppLocalizationsEn()), sentence);
    });
  });

  test('Arabic dismissal plurals and the unsupported OS line match the Bureau', () {
    final sentences = {
      1: 'أُغلق تنبيه الرنين على الهاتف. عاد الهاتف إلى الرنين.',
      2: 'أُغلق تنبيه الرنين على الهاتف مرتين. ما زال الهاتف يرنّ.',
      3: 'أُغلق تنبيه الرنين على الهاتف 3 مرات. ما زال الهاتف يرنّ.',
      11: 'أُغلق تنبيه الرنين على الهاتف 11 مرة. ما زال الهاتف يرنّ.',
    };
    sentences.forEach((count, sentence) {
      final alert = ringAlert('child_dismissed', 'alertBodyRingChildDismissed',
          {'ringId': 'ring-1', 'dismissalCount': count}, 'English fallback');
      expect(alertBodyFor(alert, AppLocalizationsAr()), sentence);
    });
    expect(commandRefusalText(AppLocalizationsAr(), 'ring', 'iPhone', 'unsupported_os'),
        'لا يمكن أن يرنّ هذا الآيفون حاليًا. يحتاج إلى iOS 26 أو أحدث.');
  });

  test('unsupported OS has a localized update reason in command history', () {
    expect(commandRefusalText(AppLocalizationsEn(), 'ring', 'iPhone', 'unsupported_os'),
        'This iPhone cannot ring yet. It needs iOS 26 or later.');
  });

  testWidgets('the Arabic dialog uses bodyKey and hides raw ring metadata', (tester) async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    final api = FakeApiClient({
      ...standardRoutes(alerts: [
        {
          'id': 'ring-alert-1', 'childId': 'child-1', 'deviceId': 'dev-1',
          'severity': 'warning', 'category': 'ring', 'title': 'Phone ring',
          'body': 'The ring alert was dismissed on the phone 2 times. It is still ringing.',
          'metadata': {
            'state': 'child_dismissed', 'ringId': 'ring-1',
            'bodyKey': 'alertBodyRingChildDismissed',
            'bodyParams': {'ringId': 'ring-1', 'dismissalCount': 2},
          },
          'createdAt': '2026-11-14T00:00:00Z', 'acknowledged': false,
        },
      ]),
    });
    await tester.pumpWidget(ProviderScope(
      overrides: [apiClientProvider.overrideWithValue(api)],
      child: localizedTestApp(const AlertsScreen(),
          locale: const Locale('ar'), textDirection: TextDirection.rtl),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('رنين الهاتف'));
    await tester.pumpAndSettle();
    expect(find.text('أُغلق تنبيه الرنين على الهاتف مرتين. ما زال الهاتف يرنّ.'), findsOneWidget);
    expect(find.textContaining('bodyKey'), findsNothing);
    expect(find.textContaining('bodyParams'), findsNothing);
    expect(find.textContaining('state:'), findsNothing);
    expect(find.textContaining('ringId:'), findsNothing);
  });
}
