import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:familyshield_parent/features/social/social_screen.dart';
import 'package:familyshield_parent/providers/auth_provider.dart';

import 'fake_api_client.dart';
import 'test_app.dart';

/// Issue #475 follow-up: the "the phone hasn't picked this change up yet" line belongs wherever a parent
/// **changes rules**, not only on the rule editor. The social screen writes two of them (monitoring toggles
/// and the contact allowlist), so it carries the same banner — and, like the editor, it must say nothing in
/// the two states where a warning would be wrong.
///
/// Mutants: treat `applied == null` as behind and [a phone that never reported shows nothing] goes red; drop
/// `RulesBehindBanner` from `SocialScreen` and [a phone behind shows the line on the social screen] goes red.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  Map<String, dynamic> child({int? rules, int? applied}) => {
        'id': 'child-1',
        'familyId': 'fam-1',
        'displayName': 'Alex',
        'birthYear': 2013,
        if (rules != null) 'rulesVersion': rules,
        if (applied != null) 'appliedRulesVersion': applied,
      };

  Future<void> pumpSocial(WidgetTester tester, Map<String, dynamic> childJson) async {
    final api = FakeApiClient({
      ...standardRoutes(familyMe: {...familyMeTwoChildren(), 'children': [childJson]}),
    });
    await tester.pumpWidget(ProviderScope(
      overrides: [apiClientProvider.overrideWithValue(api)],
      child: localizedTestApp(const SocialScreen(childId: 'child-1')),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('a phone behind shows the line on the social screen', (tester) async {
    await pumpSocial(tester, child(rules: 7, applied: 5));
    expect(find.byKey(const ValueKey('rules-behind-banner')), findsOneWidget);
    expect(find.textContaining("hasn't picked this change up yet"), findsOneWidget);
  });

  testWidgets('a phone that is current shows nothing', (tester) async {
    await pumpSocial(tester, child(rules: 7, applied: 7));
    expect(find.byKey(const ValueKey('rules-behind-banner')), findsNothing);
  });

  testWidgets('a phone that never reported shows nothing', (tester) async {
    // Null is "never reported", not "version 0": a fresh install must not be warned about.
    await pumpSocial(tester, child(rules: 7));
    expect(find.byKey(const ValueKey('rules-behind-banner')), findsNothing);
  });
}
