import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:familyshield_parent/core/date_formatting.dart';
import 'package:familyshield_parent/features/alerts/alerts_screen.dart';
import 'package:familyshield_parent/l10n/l10n.dart';
import 'package:familyshield_parent/providers/auth_provider.dart';

import 'fake_api_client.dart';
import 'test_app.dart';

/// #1128 supersedes the earlier #475 alert-dialog banner rule: an alert is not a rule change, so
/// `RulesBehindBanner` must never appear inside an alert dialog, even when the child's phone is behind.
///
/// Mutant: re-adding `RulesBehindBanner` inside `AlertsScreen._showDetail` fails rows 1 and 3 below.
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

  testWidgets('the dialog of a child whose phone is behind never shows the rules-sync banner (#1128)', (tester) async {
    await pumpAlerts(
      tester,
      children: [child('child-1', rules: 7, applied: 5)],
      alerts: [alert('a1', 'child-1', 'Meet was blocked')],
    );

    await tester.tap(find.text('Meet was blocked'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('rules-behind-banner')), findsNothing);
    expect(find.textContaining("hasn't picked this change up yet"), findsNothing);
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

  testWidgets('with two children, neither alert dialog shows the rules-sync banner (#1128)', (tester) async {
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
    expect(find.byKey(const ValueKey('rules-behind-banner')), findsNothing);
  });

  testWidgets('Arabic alert detail and day headers use Western digits', (tester) async {
    await configureDateFormatting();
    final api = FakeApiClient({
      ...standardRoutes(
        familyMe: {...familyMeTwoChildren(), 'children': [child('child-1')]},
        alerts: [alert('a1', 'child-1', 'Meet was blocked')],
      ),
    });
    await tester.pumpWidget(ProviderScope(
      overrides: [apiClientProvider.overrideWithValue(api)],
      child: localizedTestApp(const AlertsScreen(), locale: const Locale('ar')),
    ));
    await tester.pumpAndSettle();

    final visibleText = tester.widgetList<Text>(find.byType(Text)).map((text) => text.data).whereType<String>().join(' | ');
    expect(find.text('الاثنين، 19 أكتوبر 2026'), findsOneWidget, reason: visibleText);
    await tester.tap(find.byType(Dismissible));
    await tester.pumpAndSettle();

    final arabicIndicDigits = RegExp(r'[\u0660-\u0669\u06F0-\u06F9]');
    final texts = tester.widgetList<Text>(find.byType(Text)).map((text) => text.data).whereType<String>();
    for (final text in texts) {
      expect(text, isNot(contains(arabicIndicDigits)), reason: text);
    }
  });

  testWidgets('no raw key: value metadata rows or Technical details appear on any alert (#755)', (tester) async {
    final sosWithExtraMeta = {
      ...sosAlert(),
      'metadata': <String, dynamic>{
        ...(sosAlert()['metadata'] as Map<String, dynamic>),
        'bodyKey': 'alertBodySos',
        'bodyParams': {'device': 'SM-F721B'},
      },
    };
    final installReq = {
      ...alert('i1', 'child-1', 'New app installed'),
      'category': 'install_request',
      'body': 'Kid installed Fun Game',
      'metadata': <String, dynamic>{
        'packageId': 'com.example.fungame',
        'appName': 'Fun Game',
        'bodyKey': 'alertBodyInstall',
        'bodyParams': {'app': 'Fun Game'},
        'deviceId': 'dev-1',
      },
    };
    await pumpAlerts(tester, children: [child('child-1')], alerts: [sosWithExtraMeta, installReq]);

    await tester.tap(find.text('SOS pressed'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('alert-technical-details')), findsNothing);
    expect(find.textContaining('Technical details'), findsNothing);
    expect(find.textContaining('lat:'), findsNothing);
    expect(find.textContaining('lng:'), findsNothing);
    expect(find.textContaining('deviceId:'), findsNothing);
    expect(find.textContaining('bodyKey:'), findsNothing);
    expect(find.textContaining('bodyParams:'), findsNothing);
    expect(find.textContaining('takenAt:'), findsNothing);
    expect(find.textContaining('ageSeconds:'), findsNothing);
    // #755 Arabic Bureau (6868533968): SOS dialog has no body sentence (only title + place + child label).
    expect(find.descendant(of: find.byType(AlertDialog), matching: find.text('Your child pressed the SOS button')), findsNothing);
    expect(find.text('Child: Alex'), findsOneWidget);
    expect(find.descendant(of: find.byType(AlertDialog), matching: find.byType(Divider)), findsOneWidget);

    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();

    final en = lookupAppLocalizations(const Locale('en'));
    await tester.tap(find.text(en.alertTitleInstallRequest));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('alert-technical-details')), findsNothing);
    expect(find.textContaining('packageId:'), findsNothing);
    expect(find.textContaining('appName:'), findsNothing);
    expect(find.textContaining('bodyKey:'), findsNothing);
    expect(find.text('Kid installed Fun Game'), findsOneWidget);
    expect(find.text('Child: Alex'), findsOneWidget);
    expect(find.text('Block this app'), findsOneWidget);
  });

  testWidgets('Arabic SOS alert detail hides raw English SOS body & metadata and shows الطفل: Alex (#755)', (tester) async {
    final ar = lookupAppLocalizations(const Locale('ar'));
    final api = FakeApiClient({
      ...standardRoutes(
        familyMe: {...familyMeTwoChildren(), 'children': [child('child-1')]},
        alerts: [sosAlert()],
      ),
    });
    await tester.pumpWidget(ProviderScope(
      overrides: [apiClientProvider.overrideWithValue(api)],
      child: localizedTestApp(const AlertsScreen(), locale: const Locale('ar'), textDirection: TextDirection.rtl),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text(ar.alertTitleSos));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('alert-technical-details')), findsNothing);
    expect(find.textContaining('lat:'), findsNothing);
    expect(find.textContaining('deviceId:'), findsNothing);
    expect(find.descendant(of: find.byType(AlertDialog), matching: find.text('Your child pressed the SOS button')), findsNothing);
    expect(find.text('الطفل: Alex'), findsOneWidget);
    expect(find.descendant(of: find.byType(AlertDialog), matching: find.byType(Divider)), findsOneWidget);
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
