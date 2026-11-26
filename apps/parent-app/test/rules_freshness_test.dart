import 'package:familyshield_parent/api/models.dart';
import 'package:familyshield_parent/features/rules/rules_freshness.dart';
import 'package:familyshield_parent/features/rules/rules_editor_screen.dart';
import 'package:familyshield_parent/providers/auth_provider.dart';
import 'package:familyshield_parent/providers/family_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_api_client.dart';
import 'test_app.dart';

/// Issue #475 & #1157: rules freshness states ("waiting for first apply", "phone hasn't picked this change
/// up yet", and "current").
///
/// - Paired phone with `applied == null` shows `rules-waiting-banner` (not the behind warning).
/// - Unpaired child with `applied == null` shows nothing.
/// - `applied < rules` shows `rules-behind-banner`.
/// - `applied >= rules` shows nothing.
///
/// Mutants: hide `applied == null` on a paired child and [paired -> waiting -> ready] goes red; warn on
/// an unpaired child and [an unpaired child with no applied version shows nothing] goes red.
void main() {
  Child child({int? rules, int? applied}) => Child(
        id: 'child-1',
        familyId: 'fam-1',
        displayName: 'Alex',
        birthYear: 2013,
        rulesVersion: rules,
        appliedRulesVersion: applied,
      );

  group('rulesFreshness', () {
    test('paired child with no applied version yet is waitingForFirstApply', () {
      expect(
        rulesFreshness(child(rules: 1, applied: null), hasPairedDevice: true),
        RulesFreshness.waitingForFirstApply,
      );
    });

    test('unpaired child with no applied version stays current', () {
      expect(
        rulesFreshness(child(rules: 1, applied: null), hasPairedDevice: false),
        RulesFreshness.current,
      );
    });

    test('paired child with applied version below ruleset is behind', () {
      expect(
        rulesFreshness(child(rules: 7, applied: 5), hasPairedDevice: true),
        RulesFreshness.behind,
      );
    });

    test('paired child with applied version matching ruleset is current', () {
      expect(
        rulesFreshness(child(rules: 7, applied: 7), hasPairedDevice: true),
        RulesFreshness.current,
      );
    });

    test('older server without rulesVersion stays current even when paired', () {
      expect(
        rulesFreshness(child(rules: null, applied: null), hasPairedDevice: true),
        RulesFreshness.current,
      );
    });

    test('applied version higher than rulesVersion stays current', () {
      expect(
        rulesFreshness(child(rules: 5, applied: 7), hasPairedDevice: true),
        RulesFreshness.current,
      );
    });
  });

  group('rulesAreBehind', () {
    test('an applied version below the ruleset is behind', () {
      expect(rulesAreBehind(child(rules: 7, applied: 5)), isTrue);
    });

    test('the same version is not behind', () {
      expect(rulesAreBehind(child(rules: 7, applied: 7)), isFalse);
    });

    test('a device that never reported is waiting, not behind', () {
      // Null is "never reported", not "version 0": a fresh install must not raise the behind warning.
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
    Future<void> flushFakeHttp(WidgetTester tester) async {
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    Future<void> pumpEditor(
      WidgetTester tester,
      Map<String, dynamic> childJson, {
      List<Map<String, dynamic>>? devices,
      Locale locale = const Locale('en'),
      TextDirection textDirection = TextDirection.ltr,
    }) async {
      final base = familyMeTwoChildren();
      final api = FakeApiClient({
        ...standardRoutes(familyMe: {
          ...base,
          'children': [childJson],
          if (devices != null) 'devices': devices,
        }),
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
      expect(find.byKey(const ValueKey('rules-waiting-banner')), findsNothing);
      expect(find.textContaining("hasn't picked this change up yet"), findsOneWidget);
    });

    testWidgets('saving a rule shows the line, because the family is refetched', (tester) async {
      // #501 review, point 1: `_save()` invalidated only `rulesProvider`, so the family snapshot kept the
      // pre-save version — `applied == rules`, and the banner the parent had just earned never appeared.
      // The row saves and answers the refetch with the bumped version, which is what a real server does.
      // Mutant: drop `ref.invalidate(familyProvider)` from `_save()` and this row goes red, while every
      // other row here stays green — which is exactly why it exists.
      final childJson = <String, dynamic>{
        'id': 'child-1',
        'familyId': 'fam-1',
        'displayName': 'Alex',
        'birthYear': 2013,
        'rulesVersion': 7,
        'appliedRulesVersion': 7,
      };
      await pumpEditor(tester, childJson);
      expect(find.byKey(const ValueKey('rules-behind-banner')), findsNothing);

      childJson['rulesVersion'] = 8; // the PUT bumped it; the phone still has 7
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('rules-behind-banner')), findsOneWidget);
      expect(find.textContaining("hasn't picked this change up yet"), findsOneWidget);
    });

    testWidgets('an unpaired child with no applied version shows nothing', (tester) async {
      await pumpEditor(
        tester,
        {
          'id': 'child-1',
          'familyId': 'fam-1',
          'displayName': 'Alex',
          'birthYear': 2013,
          'rulesVersion': 1,
        },
        devices: const [],
      );
      expect(find.byKey(const ValueKey('rules-waiting-banner')), findsNothing);
      expect(find.byKey(const ValueKey('rules-behind-banner')), findsNothing);
    });

    testWidgets('paired -> waiting -> ready -> behind transition (#1157)', (tester) async {
      final base = familyMeTwoChildren();
      final pairedDevices = (base['devices'] as List).cast<Map<String, dynamic>>();
      var devices = <Map<String, dynamic>>[];
      final childJson = <String, dynamic>{
        'id': 'child-1',
        'familyId': 'fam-1',
        'displayName': 'Alex',
        'birthYear': 2013,
        'rulesVersion': 1,
      };
      final api = FakeApiClient({
        ...standardRoutes(familyMe: base),
        'GET /v1/family/me': (_) => {
              ...base,
              'children': [Map<String, dynamic>.from(childJson)],
              'devices': devices,
            },
      });
      await tester.pumpWidget(ProviderScope(
        overrides: [apiClientProvider.overrideWithValue(api)],
        child: localizedTestApp(const RulesEditorScreen(childId: 'child-1')),
      ));
      await tester.pumpAndSettle();

      // 1. Before pairing: neither waiting nor behind banner appears.
      expect(find.byKey(const ValueKey('rules-waiting-banner')), findsNothing);
      expect(find.byKey(const ValueKey('rules-behind-banner')), findsNothing);

      // 2. Phone pairs, rulesVersion=1, appliedRulesVersion still null -> explicit waiting banner.
      devices = pairedDevices;
      final container = ProviderScope.containerOf(tester.element(find.byType(RulesEditorScreen)));
      container.invalidate(familyProvider);
      await flushFakeHttp(tester);
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('rules-waiting-banner')), findsOneWidget);
      expect(find.text('Waiting for the phone to apply rules.'), findsOneWidget);
      expect(find.byKey(const ValueKey('rules-behind-banner')), findsNothing);

      // 3. First applied version arrives (appliedRulesVersion=1) -> waiting clears (ready).
      childJson['appliedRulesVersion'] = 1;
      container.invalidate(familyProvider);
      await flushFakeHttp(tester);
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('rules-waiting-banner')), findsNothing);
      expect(find.byKey(const ValueKey('rules-behind-banner')), findsNothing);

      // 4. Subsequent rules bump while phone still has 1 -> normal behind banner takes over.
      childJson['rulesVersion'] = 2;
      container.invalidate(familyProvider);
      await flushFakeHttp(tester);
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('rules-waiting-banner')), findsNothing);
      expect(find.byKey(const ValueKey('rules-behind-banner')), findsOneWidget);
      expect(find.textContaining("hasn't picked this change up yet"), findsOneWidget);
    });

    testWidgets('a phone that is current shows nothing, and a paired unreported phone shows waiting not behind',
        (tester) async {
      await pumpEditor(tester, {
        'id': 'child-1',
        'familyId': 'fam-1',
        'displayName': 'Alex',
        'birthYear': 2013,
        'rulesVersion': 7,
        'appliedRulesVersion': 7,
      });
      expect(find.byKey(const ValueKey('rules-behind-banner')), findsNothing);
      expect(find.byKey(const ValueKey('rules-waiting-banner')), findsNothing);

      await pumpEditor(tester, {
        'id': 'child-1',
        'familyId': 'fam-1',
        'displayName': 'Alex',
        'birthYear': 2013,
        'rulesVersion': 7,
      });
      expect(find.byKey(const ValueKey('rules-behind-banner')), findsNothing);
      expect(find.byKey(const ValueKey('rules-waiting-banner')), findsOneWidget);
    });

    testWidgets('the Arabic waiting line renders cleanly in RTL (#1157)', (tester) async {
      await pumpEditor(
        tester,
        {
          'id': 'child-1',
          'familyId': 'fam-1',
          'displayName': 'Alex',
          'birthYear': 2013,
          'rulesVersion': 1,
        },
        locale: const Locale('ar'),
        textDirection: TextDirection.rtl,
      );
      expect(find.byKey(const ValueKey('rules-waiting-banner')), findsOneWidget);
      expect(find.text('بانتظار أن يطبّق الهاتف القواعد.'), findsOneWidget);
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
      expect(find.text('لم يستلم الهاتف هذا التغيير بعد.'), findsOneWidget);
    });
  });
}
