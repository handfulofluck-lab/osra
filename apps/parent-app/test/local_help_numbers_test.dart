import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:familyshield_parent/features/coach/coach_card_section.dart';
import 'package:familyshield_parent/features/coach/coach_content.dart';
import 'package:familyshield_parent/features/coach/local_help_numbers.dart';

import 'test_app.dart';

/// Issue #723: a coaching card carries the right number for the family's
/// country, or a sentence with no number in it — never `[add local number]`.
///
/// The country rows themselves come from Claude with one source per number; the
/// fixtures here are deliberately not real numbers, so a test can never be the
/// thing that introduces one.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const fixtureTable = <String, LocalHelpNumbers>{
    'AE': LocalHelpNumbers(
        emergency: '100', childProtection: '116111', crisis: '80046342'),
    'DE': LocalHelpNumbers(emergency: '112'),
  };

  group('resolveHelpNumbers', () {
    test('a country row fills all three fields', () {
      final n = resolveHelpNumbers(
          countryCode: 'AE', region: 'OTHER', table: fixtureTable);
      expect(n.emergency, '100');
      expect(n.childProtection, '116111');
      expect(n.crisis, '80046342');
    });

    test(
        'a lower-case country code matches, and the region does not override the row',
        () {
      final n = resolveHelpNumbers(
          countryCode: 'ae', region: 'EU', table: fixtureTable);
      expect(n.emergency, '100', reason: 'the row wins over the region');
    });

    test('an unknown country with region OTHER knows nothing', () {
      final n = resolveHelpNumbers(
          countryCode: 'ZZ', region: 'OTHER', table: fixtureTable);
      expect(n, LocalHelpNumbers.none);
    });

    test('EU fills the emergency number only, and only for an unknown country',
        () {
      final n = resolveHelpNumbers(
          countryCode: 'ZZ', region: 'EU', table: fixtureTable);
      expect(n.emergency, '112');
      expect(n.childProtection, isNull,
          reason: 'child-protection lines differ inside the EU');
      expect(n.crisis, isNull, reason: 'crisis lines differ inside the EU');
    });

    test('US and UK resolve from the region for an unknown country', () {
      expect(
          resolveHelpNumbers(
                  countryCode: null, region: 'US', table: fixtureTable)
              .emergency,
          '911');
      expect(
          resolveHelpNumbers(
                  countryCode: null, region: 'uk', table: fixtureTable)
              .emergency,
          '999');
    });

    test(
        'a row that leaves the emergency number empty is filled from the region',
        () {
      final n = resolveHelpNumbers(
          countryCode: 'DE', region: 'EU', table: fixtureTable);
      expect(n.crisis, isNull);
      expect(n.emergency, '112');
    });
  });

  group('clauses', () {
    test('a known number reads as a clause in both languages', () {
      const n = LocalHelpNumbers(
          emergency: '999', childProtection: '116111', crisis: '116123');
      // The number is wrapped in LRI/PDI in every language: see the direction group below.
      expect(n.emergencyClause(arabic: false), 'call emergency services on \u2066999\u2069');
      expect(n.crisisClause(arabic: false), 'call the crisis line on \u2066116123\u2069');
      expect(n.childProtectionClause(arabic: false), 'call the child-protection line on \u2066116111\u2069');
      expect(n.emergencyClause(arabic: true), 'اتصل بالطوارئ على الرقم \u2066999\u2069');
    });

    test(
        'a missing number is a sentence with no digits in it, in both languages',
        () {
      const n = LocalHelpNumbers.none;
      for (final clause in [
        n.emergencyClause(arabic: false),
        n.crisisClause(arabic: false),
        n.childProtectionClause(arabic: false),
        n.emergencyClause(arabic: true),
        n.crisisClause(arabic: true),
        n.childProtectionClause(arabic: true),
      ]) {
        expect(RegExp(r'\d').hasMatch(clause), isFalse, reason: clause);
        expect(clause.contains('['), isFalse, reason: clause);
        expect(clause.contains(']'), isFalse, reason: clause);
      }
    });
  });

  group('fillHelpNumbers', () {
    test('every token is substituted, and no braces survive into the card', () {
      final card = _selfHarmCard();
      final filled = fillHelpNumbers(
          card.body, const LocalHelpNumbers(emergency: '999', crisis: '116123'),
          arabic: false);
      expect(filled.contains('{'), isFalse, reason: filled);
      expect(filled, contains('call emergency services on \u2066999\u2069'));
      expect(filled, contains('call the crisis line on \u2066116123\u2069'));
    });

    test(
        'an empty table still renders a card with no placeholder and no digits for the numbers',
        () {
      final card = _selfHarmCard();
      final filled =
          fillHelpNumbers(card.body, LocalHelpNumbers.none, arabic: false);
      expect(filled, contains("call your country's emergency number"));
      expect(filled, contains('call the crisis line in your country'));
      expect(filled.contains('[add local number]'), isFalse);
    });

    test('text with no token is returned unchanged', () {
      expect(
          fillHelpNumbers('Stay calm.', LocalHelpNumbers.none, arabic: false),
          'Stay calm.');
    });
  });

  test(
      'the coaching cards, and every Dart file under lib/, carry no number placeholder',
      () {
    const forbidden = ['[add local number]', '[أضف الرقم المحلي]'];
    for (final card in [coachCardFor('self_harm'), coachCardFor('grooming')]) {
      for (final text in [
        card.title,
        card.titleAr,
        card.body,
        card.bodyAr,
        ...card.tips,
        ...card.tipsAr
      ]) {
        for (final bad in forbidden) {
          expect(text.contains(bad), isFalse, reason: text);
        }
      }
    }

    final offenders = <String>[];
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final text = entity.readAsStringSync();
      for (final bad in forbidden) {
        if (text.contains(bad)) offenders.add('${entity.path}: $bad');
      }
    }
    expect(offenders, isEmpty,
        reason: 'a placeholder number reached the app: $offenders');
  });

  testWidgets(
      'the card renders the sentence with no number when the device country is unknown',
      (tester) async {
    tester.binding.platformDispatcher.localeTestValue =
        const Locale('en', 'ZZ');
    addTearDown(tester.binding.platformDispatcher.clearLocaleTestValue);
    await tester.pumpWidget(localizedTestApp(
      Scaffold(body: CoachCardSection(card: coachCardFor('self_harm'))),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('How to talk about this'));
    await tester.pumpAndSettle();

    expect(
        find.textContaining("call your country's emergency number"), findsWidgets);
    expect(find.textContaining('[add local number]'), findsNothing);
  });

  testWidgets('the Arabic card renders the Arabic sentence', (tester) async {
    tester.binding.platformDispatcher.localeTestValue =
        const Locale('ar', 'ZZ');
    addTearDown(tester.binding.platformDispatcher.clearLocaleTestValue);
    await tester.pumpWidget(localizedTestApp(
      Scaffold(body: CoachCardSection(card: coachCardFor('self_harm'))),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('How to talk about this'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('coachLangToggle')));
    await tester.pumpAndSettle();

    expect(find.textContaining('اتصل برقم الطوارئ في بلدك'), findsWidgets);
  });

  group('direction of a number inside a sentence (#727 Arabic Bureau)', () {
    // The Bureau's finding: `800 46342` in a right-to-left line is laid out from the right, so the card
    // shows `46342 800` - and a parent in a crisis dials what the card shows. The isolate must wrap the
    // WHOLE number, which is why the rows use a number with a space and one with a leading '+': an
    // unbroken number would hide the bug, which is exactly why the earlier rows missed it.
    test('a number with a space is isolated as a whole, so its groups keep their order', () {
      const n = LocalHelpNumbers(crisis: '800 46342');
      final clause = n.crisisClause(arabic: true);
      expect(clause, contains('\u2066800 46342\u2069'));
      expect(clause.indexOf('\u2066'), lessThan(clause.indexOf('800')));
      expect(clause.indexOf('\u2069'), greaterThan(clause.indexOf('46342')));
    });

    test('a number that starts with + is isolated too', () {
      const n = LocalHelpNumbers(emergency: '+44 999');
      expect(n.emergencyClause(arabic: true), contains('\u2066+44 999\u2069'));
    });

    test('the English sentence isolates the number as well', () {
      const n = LocalHelpNumbers(crisis: '800 46342');
      expect(n.crisisClause(arabic: false), contains('\u2066800 46342\u2069'));
    });
  });
}

/// The shipped self-harm card, reached through the public lookup so the test
/// fails if the card is ever detached from its category.
CoachCard _selfHarmCard() => coachCardFor('self_harm');
