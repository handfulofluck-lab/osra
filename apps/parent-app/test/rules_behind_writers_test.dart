import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:familyshield_parent/features/children/child_detail_screen.dart';
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

  // The bonus card: a grant bumps `rulesVersion` (controls.ts:88), so the card that grants it is the third
  // place a parent needs the line. Same three states, same widget.
  Future<void> pumpDetail(WidgetTester tester, Map<String, dynamic> childJson) async {
    final api = FakeApiClient({
      ...standardRoutes(familyMe: {...familyMeTwoChildren(), 'children': [childJson]}),
    });
    await tester.pumpWidget(ProviderScope(
      overrides: [apiClientProvider.overrideWithValue(api)],
      child: localizedTestApp(const ChildDetailScreen(childId: 'child-1')),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('the bonus card shows the line when the phone is behind', (tester) async {
    await pumpDetail(tester, child(rules: 7, applied: 5));
    expect(find.byKey(const ValueKey('rules-behind-banner')), findsOneWidget);
  });

  testWidgets('the bonus card says nothing when the phone is current', (tester) async {
    await pumpDetail(tester, child(rules: 7, applied: 7));
    expect(find.byKey(const ValueKey('rules-behind-banner')), findsNothing);
  });

  testWidgets('the bonus card says nothing when the phone never reported', (tester) async {
    await pumpDetail(tester, child(rules: 7));
    expect(find.byKey(const ValueKey('rules-behind-banner')), findsNothing);
  });

  testWidgets('a grant shows the line, because the family is refetched', (tester) async {
    // Claude's fault for this screen: no family refresh after the write. The row grants, the refetch answers
    // with the bumped version, and only then is the line earned - so dropping the invalidation reddens this
    // row and nothing else.
    final childJson = child(rules: 7, applied: 7);
    final api = FakeApiClient({
      ...standardRoutes(familyMe: {...familyMeTwoChildren(), 'children': [childJson]}),
      'POST /v1/controls/children/child-1/bonus': (_) => {'ok': true},
    });
    await tester.pumpWidget(ProviderScope(
      overrides: [apiClientProvider.overrideWithValue(api)],
      child: localizedTestApp(const ChildDetailScreen(childId: 'child-1')),
    ));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('rules-behind-banner')), findsNothing);

    childJson['rulesVersion'] = 8; // the grant bumped it; the phone still has 7
    // The card sits below the fold on a 800x600 test surface: scroll it in, or the tap lands nowhere.
    await tester.ensureVisible(find.text('+15'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('+15'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('rules-behind-banner')), findsOneWidget);
  });
}
