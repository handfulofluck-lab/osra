import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:familyshield_parent/features/alerts/alerts_screen.dart';
import 'package:familyshield_parent/providers/auth_provider.dart';

import 'fake_api_client.dart';
import 'test_app.dart';

/// Issue #475 follow-up, Claude's ruling on `alerts_screen`: the feed is family-wide and carries no line, but
/// the **detail dialog** is scoped to one alert's child, so that is where a parent who opens an alert later
/// learns whether their last change landed.
///
/// This is the alerts screen's first widget test, and the third row is the one that matters: with two
/// children where only one is behind, a banner keyed to the wrong child would still pass rows 1 and 2.
///
/// Mutants: remove the banner and rows 1 and 3 go red; key it to `children.first` instead of `alert.childId`
/// and row 3 alone goes red.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  Map<String, dynamic> child(String id, {int? rules, int? applied}) => {
        'id': id,
        'familyId': 'fam-1',
        'displayName': id == 'child-1' ? 'Alex' : 'Sam',
        'birthYear': 2013,
        if (rules != null) 'rulesVersion': rules,
        if (applied != null) 'appliedRulesVersion': applied,
      };

  Map<String, dynamic> alert(String id, String childId, String title) => {
        'id': id,
        'childId': childId,
        'deviceId': 'dev-1',
        'severity': 'warning',
        // An unmapped category renders the server title verbatim (`alertTitleFor` falls back to it), so
        // each alert in this file is findable by its own title; a mapped one would show "App blocked" twice.
        'category': 'unmapped_for_this_test',
        'title': title,
        'body': '$title body',
        'metadata': <String, dynamic>{},
        'createdAt': DateTime.utc(2026, 10, 19, 12).toIso8601String(),
        'acknowledged': false,
      };

  Map<String, dynamic> sosAlert() => {
        ...alert('s1', 'child-1', 'SOS from SM-F721B'),
        'category': 'sos',
        'severity': 'critical',
        'body': 'Your child pressed the SOS button',
        'metadata': <String, dynamic>{
          'deviceId': 'dev-1',
          'lat': 25.2769,
          'lng': 51.5211,
          'accuracyM': 20,
          'takenAt': DateTime.utc(2026, 10, 19, 11, 57).toIso8601String(),
          'ageSeconds': 180,
        },
      };

  Future<void> pumpAlerts(
    WidgetTester tester, {
    required List<Map<String, dynamic>> children,
    required List<Map<String, dynamic>> alerts,
  }) async {
    final api = FakeApiClient({
      ...standardRoutes(
        familyMe: {...familyMeTwoChildren(), 'children': children},
        alerts: alerts,
      ),
    });
    await tester.pumpWidget(ProviderScope(
      overrides: [apiClientProvider.overrideWithValue(api)],
      child: localizedTestApp(const AlertsScreen()),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('the dialog of a child whose phone is behind shows the line', (tester) async {
    await pumpAlerts(
      tester,
      children: [child('child-1', rules: 7, applied: 5)],
      alerts: [alert('a1', 'child-1', 'Meet was blocked')],
    );

    await tester.tap(find.text('Meet was blocked'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('rules-behind-banner')), findsOneWidget);
    expect(find.textContaining("hasn't picked this change up yet"), findsOneWidget);
  });

  testWidgets('the dialog of a child whose phone is current shows nothing', (tester) async {
    await pumpAlerts(
      tester,
      children: [child('child-1', rules: 7, applied: 7)],
      alerts: [alert('a1', 'child-1', 'Meet was blocked')],
    );

    await tester.tap(find.text('Meet was blocked'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('rules-behind-banner')), findsNothing);
  });

  testWidgets('with two children, the line follows the alert\'s own child', (tester) async {
    // Only Sam's phone is behind. Alex's alert must stay clean, or a banner keyed to the wrong child
    // would be telling a parent the wrong phone is out of date.
    await pumpAlerts(
      tester,
      children: [
        child('child-1', rules: 7, applied: 7),
        child('child-2', rules: 7, applied: 5),
      ],
      alerts: [
        alert('a1', 'child-1', 'Alex: Meet was blocked'),
        alert('a2', 'child-2', 'Sam: Meet was blocked'),
      ],
    );

    await tester.tap(find.text('Alex: Meet was blocked'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('rules-behind-banner')), findsNothing);

    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Sam: Meet was blocked'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('rules-behind-banner')), findsOneWidget);
  });

  testWidgets('an SOS detail shows no raw lat: row until Technical details is opened (#743)', (tester) async {
    // The old behaviour printed every metadata entry as `key: value` under the sentence, so an SOS showed
    // `lat: 25.2769`, a machine timestamp and the device id in English developer words on an Arabic screen.
    await pumpAlerts(tester, children: [child('child-1')], alerts: [sosAlert()]);

    await tester.tap(find.text('SOS pressed'));
    await tester.pumpAndSettle();

    expect(find.textContaining('lat:'), findsNothing, reason: 'no developer row is shown by default');
    final section = find.byKey(const ValueKey('alert-technical-details'));
    expect(section, findsOneWidget);

    await tester.ensureVisible(section);
    await tester.pumpAndSettle();
    await tester.tap(section);
    await tester.pumpAndSettle();

    expect(find.textContaining('lat:'), findsOneWidget, reason: 'the rows are there when a parent asks');
  });

  testWidgets('the location line reads as body text, not as a detail (#743 UI/UX)', (tester) async {
    // The place is a sentence a parent reads, so it takes the dialog's default body style; only the
    // accuracy under it is small and muted. The row fails if the line falls back to bodySmall.
    await pumpAlerts(tester, children: [child('child-1')], alerts: [sosAlert()]);

    await tester.tap(find.text('SOS pressed'));
    await tester.pumpAndSettle();

    final line = tester.widget<Text>(find.byKey(const ValueKey('alert-sos-location-line')));
    final theme = Theme.of(tester.element(find.byKey(const ValueKey('alert-sos-location-line'))));
    expect(line.style?.fontSize, isNot(theme.textTheme.bodySmall?.fontSize),
        reason: 'the location line must not be the detail style');
    expect(line.style, isNull, reason: 'no explicit style means the dialog default, which is the point');
  });
}
