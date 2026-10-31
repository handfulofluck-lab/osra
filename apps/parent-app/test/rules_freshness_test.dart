import 'package:familyshield_parent/api/models.dart';
import 'package:familyshield_parent/features/rules/rules_freshness.dart';
import 'package:familyshield_parent/features/rules/rules_editor_screen.dart';
import 'package:familyshield_parent/providers/auth_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_api_client.dart';
import 'test_app.dart';

/// Issue #475: "the phone hasn't picked this up yet", and the three states behind it.
///
/// Only one of them warns. A phone that has never reported is **not** a phone that is behind — a warning
/// there would fire on every fresh install and teach the parent to ignore the one that matters.
///
/// Mutants: return `applied != rules` (which warns on a device that never reported) and
/// [a device that never reported says nothing] goes red; drop the banner and the widget row goes red.
void main() {
  Child child({int? rules, int? applied}) => Child(
        id: 'child-1',
        familyId: 'fam-1',
        displayName: 'Alex',
        birthYear: 2013,
        rulesVersion: rules,
        appliedRulesVersion: applied,
      );

  group('rulesAreBehind', () {
    test('an applied version below the ruleset is behind', () {
      expect(rulesAreBehind(child(rules: 7, applied: 5)), isTrue);
    });

    test('the same version is not behind', () {
      expect(rulesAreBehind(child(rules: 7, applied: 7)), isFalse);
    });

    test('a device that never reported says nothing', () {
      // Null is "never reported", not "version 0": a fresh install must not produce a warning.
      expect(rulesAreBehind(child(rules: 7, applied: null)), isFalse);
    });

    test('a server that does not send a version says nothing', () {
      expect(rulesAreBehind(child(rules: null, applied: 5)), isFalse);
    });

    test('a version we did not issue is not a reason to warn', () {
      // The server only stores versions it issued; if one arrives higher, that is a bug, and a warning
      // built on it would be a second one.
      expect(rulesAreBehind(child(rules: 5, applied: 7)), isFalse);
    });
  });

  group('the rule screen says so', () {
    Future<void> pumpEditor(
      WidgetTester tester,
      Map<String, dynamic> childJson, {
      Locale locale = const Locale('en'),
      TextDirection textDirection = TextDirection.ltr,
    }) async {
      final api = FakeApiClient({
        ...standardRoutes(familyMe: {...familyMeTwoChildren(), 'children': [childJson]}),
      });
      await tester.pumpWidget(ProviderScope(
        overrides: [apiClientProvider.overrideWithValue(api)],
        child: localizedTestApp(
          const RulesEditorScreen(childId: 'child-1'),
          locale: locale,
          textDirection: textDirection,
        ),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('a phone behind shows the line under the rule screens', (tester) async {
      await pumpEditor(tester, {
        'id': 'child-1',
        'familyId': 'fam-1',
        'displayName': 'Alex',
        'birthYear': 2013,
        'rulesVersion': 7,
        'appliedRulesVersion': 5,
      });
      expect(find.byKey(const ValueKey('rules-behind-banner')), findsOneWidget);
      expect(find.textContaining("hasn't picked this change up yet"), findsOneWidget);
    });

    testWidgets('a phone that is current, or has never reported, shows nothing', (tester) async {
      await pumpEditor(tester, {
        'id': 'child-1',
        'familyId': 'fam-1',
        'displayName': 'Alex',
        'birthYear': 2013,
        'rulesVersion': 7,
        'appliedRulesVersion': 7,
      });
      expect(find.byKey(const ValueKey('rules-behind-banner')), findsNothing);

      await pumpEditor(tester, {
        'id': 'child-1',
        'familyId': 'fam-1',
        'displayName': 'Alex',
        'birthYear': 2013,
        'rulesVersion': 7,
      });
      expect(find.byKey(const ValueKey('rules-behind-banner')), findsNothing);
    });

    testWidgets('the Arabic line is Karim\'s wording, in RTL', (tester) async {
      // Karim's approved Arabic, pinned as a literal the way #486 and #491 pin theirs: an ARB generator, a
      // merge or a well-meaning translation that replaces the words turns this red instead of shipping
      // quietly, and the RTL pass proves the banner lays out under `ar` rather than only translating.
      await pumpEditor(
        tester,
        {
          'id': 'child-1',
          'familyId': 'fam-1',
          'displayName': 'Alex',
          'birthYear': 2013,
          'rulesVersion': 7,
          'appliedRulesVersion': 5,
        },
        locale: const Locale('ar'),
        textDirection: TextDirection.rtl,
      );
      expect(find.byKey(const ValueKey('rules-behind-banner')), findsOneWidget);
      expect(find.text('لم يلتقط الهاتف هذا التغيير بعد.'), findsOneWidget);
    });
  });
}
