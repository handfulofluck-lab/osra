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

  // Arabic Language Bureau (6899383505) and UI/UX Bureau (6899386994), item 1 of 6899250238: the grooming card ends on
  // the same emergency sentence the self-harm card already carries, in both languages, and the Arabic sets the urgent
  // case apart with «أما إذا … فـ» rather than a second «وإذا» — report for the one, call now for the other.
  test('the grooming card ends on the emergency sentence, in both languages', () {
    final card = coachCardFor('grooming');
    expect(card.body,
        endsWith('contact the police. If there is immediate danger, {emergency}.'));
    expect(
        card.tips[4],
        'If requests were sexual or threatening, {childProtection} or contact '
        'the police. If there is immediate danger, {emergency}.');
    expect(card.bodyAr,
        endsWith('أو تواصل مع الشرطة. أما إذا كان هناك خطر داهم ف{emergency}.'));
    expect(
        card.tipsAr[4],
        'إذا كانت الطلبات جنسية أو تهديدية ف{childProtection} أو تواصل مع الشرطة. '
        'أما إذا كان هناك خطر داهم ف{emergency}.');
  });

  // The Bureau's own correction: a command that answers «إذا» takes «فـ». The tip read «… داهم، ابقَ …» since 13 Nov.
  test('the self-harm tip puts فـ before the command, not a comma', () {
    final card = coachCardFor('self_harm');
    expect(card.tipsAr[3], 'إذا كان هناك خطر داهم فابقَ معه و{emergency}.');
    expect(card.tipsAr[3].contains('،'), isFalse,
        reason: 'a command answering «إذا» takes «فـ», not a comma');
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
      // U+00A0 inside the isolate (#727 UI/UX): the groups are one unbreakable run, so they cannot
      // land on two lines either.
      expect(clause, contains('\u2066800\u00A046342\u2069'));
      expect(clause.indexOf('\u2066'), lessThan(clause.indexOf('800')));
      expect(clause.indexOf('\u2069'), greaterThan(clause.indexOf('46342')));
    });

    test('a number that starts with + is isolated too', () {
      const n = LocalHelpNumbers(emergency: '+44 999');
      expect(n.emergencyClause(arabic: true), contains('\u2066+44\u00A0999\u2069'));
    });

    test('the English sentence isolates the number as well', () {
      const n = LocalHelpNumbers(crisis: '800 46342');
      expect(n.crisisClause(arabic: false), contains('\u2066800\u00A046342\u2069'));
    });
  });

  group('opening hours and steps (#727 UI/UX Bureau)', () {
    // The card never works out whether a line is open: a wrong "closed" stops a parent calling a line
    // that would have answered. It shows the hours the Bureaus worded, inside the sentence, right after
    // the number, and the emergency number is always beside it.
    test('the hours sit in brackets directly after the number, in the same sentence', () {
      const n = LocalHelpNumbers(crisis: '800 4673', crisisHoursEn: '(open daily 08:00-20:00)');
      expect(n.crisisClause(arabic: false),
          'call the crisis line on \u2066800\u00A04673\u2069 (open daily 08:00-20:00)');
    });

    test('a step comes before the hours, and the number itself stays diallable', () {
      const n = LocalHelpNumbers(
        crisis: '16000',
        stepEn: 'and choose option 4',
        crisisHoursEn: '(open Saturday to Thursday 08:00-18:00)',
      );
      final clause = n.crisisClause(arabic: false);
      expect(clause, 'call the crisis line on \u206616000\u2069 and choose option 4 '
          '(open Saturday to Thursday 08:00-18:00)');
      expect(clause.indexOf('and choose'), lessThan(clause.indexOf('(open')));
    });

    test('no hours means no bracket at all, not an empty pair', () {
      const n = LocalHelpNumbers(emergency: '999');
      expect(n.emergencyClause(arabic: false), isNot(contains('(')));
      expect(n.emergencyClause(arabic: true), isNot(contains('(')));
    });

    test('the Arabic clause carries the Arabic bracket it is given', () {
      const n = LocalHelpNumbers(emergency: '999', emergencyHoursAr: '(+ساعات)');
      expect(n.emergencyClause(arabic: true), contains('(+ساعات)'));
      expect(n.emergencyClause(arabic: false), isNot(contains('+ساعات')), reason: 'the English card never borrows the Arabic bracket');
    });
  });

  group('the country table (#723 rows, #727 hours)', () {
    // The rows are Claude's from #723; the brackets are the two Bureaus' (6869947527 Arabic,
    // 6869971353 UI/UX) and the architect's rulings (6869989999). Each row names the mutant it kills.

    test('SA crisis renders its Saturday hours in the whole sentence, both languages', () {
      final sa = helpNumbersByCountry['SA']!;
      expect(sa.crisis, '920033360');
      expect(sa.crisisHoursEn, '(open 08:00–20:00; Saturdays 13:00–20:00)',
          reason: 'the Saturday hours are the architect ruling 6869989999');
      expect(sa.crisisHoursAr, '(يعمل من 08:00 إلى 20:00، ويوم السبت من 13:00 إلى 20:00)');
      expect(sa.crisisClause(arabic: true),
          'اتصل بخط الدعم النفسي على الرقم \u2066920033360\u2069 '
          '(يعمل من 08:00 إلى 20:00، ويوم السبت من 13:00 إلى 20:00)');
      expect(sa.crisisClause(arabic: false),
          'call the crisis line on \u2066920033360\u2069 '
          '(open 08:00–20:00; Saturdays 13:00–20:00)');
      expect(sa.emergencyClause(arabic: false), isNot(contains('(')),
          reason: 'mutant: one hours pair per row would put the crisis bracket after 999');
    });

    test('Qatar: the step comes before the bracket, byte for byte', () {
      final qa = helpNumbersByCountry['QA']!;
      expect(qa.crisis, '16000', reason: 'the step is not part of the number');
      final clause = qa.crisisClause(arabic: true);
      expect(clause,
          'اتصل بخط الدعم النفسي على الرقم \u206616000\u2069 ثم اختر الرقم 4 '
          '(يعمل من السبت إلى الخميس من 08:00 إلى 18:00)');
      expect(clause.indexOf('ثم اختر الرقم 4'), lessThan(clause.indexOf('(يعمل')));
      expect(qa.crisisClause(arabic: false),
          'call the crisis line on \u206616000\u2069 and choose option 4 '
          '(open Saturday to Thursday 08:00–18:00)');
      expect(qa.childProtectionClause(arabic: false), isNot(contains('option 4')),
          reason: 'mutant: the step applied to the child-protection line too');
    });

    test('a 24-hour line carries the 24-hour bracket in both languages', () {
      final bh = helpNumbersByCountry['BH']!;
      expect(bh.childProtectionHoursEn, '(open 24 hours)');
      expect(bh.childProtectionHoursAr, '(يعمل على مدار الساعة)');
      expect(bh.childProtectionClause(arabic: false),
          'call the child-protection line on \u2066998\u2069 (open 24 hours)');
      expect(bh.childProtectionClause(arabic: true),
          'اتصل بخط حماية الطفل على الرقم \u2066998\u2069 (يعمل على مدار الساعة)');
    });

    test('a line with no stated hours has no bracket at all, and null hours', () {
      final ae = helpNumbersByCountry['AE']!;
      expect(ae.childProtectionHoursEn, isNull);
      expect(ae.childProtectionHoursAr, isNull);
      final english = ae.childProtectionClause(arabic: false);
      final arabic = ae.childProtectionClause(arabic: true);
      expect(english, isNot(contains('(')));
      expect(arabic, isNot(contains('(')));
      expect(english, contains('\u2066116111\u2069'));
      expect(arabic, contains('\u2066116111\u2069'));
    });

    test('the shown UK number has no U+0020; the dialled value keeps its spaces', () {
      final gb = helpNumbersByCountry['GB']!;
      expect(gb.childProtection, '0808 800 5000',
          reason: 'mutant: the NBSP baked into the field instead of the shown form');
      expect(gb.childProtection, contains('\u0020'));
      final shown = LocalHelpNumbers.isolatedNumber(gb.childProtection!);
      expect(shown, '\u20660808\u00A0800\u00A05000\u2069');
      expect(shown.contains('\u0020'), isFalse);
      expect(gb.childProtectionClause(arabic: false), contains(shown));
      expect(gb.childProtectionClause(arabic: true), contains(shown));
    });

    test('the UK helpline is Mon-Fri 10:00-16:00, sourced from NSPCC Learning', () {
      final gb = helpNumbersByCountry['GB']!;
      expect(gb.childProtectionHoursEn, '(open Monday to Friday 10:00–16:00)');
      expect(gb.childProtectionHoursAr, '(يعمل من الاثنين إلى الجمعة من 10:00 إلى 16:00)');

      final lines = File('lib/features/coach/local_help_numbers.dart').readAsStringSync().split('\n');
      final row = lines.indexWhere((l) => l.contains("'GB': LocalHelpNumbers("));
      expect(row, greaterThan(0), reason: 'the GB row is in the table');
      final comment = <String>[];
      for (var i = row - 1; i >= 0 && lines[i].trimLeft().startsWith('//'); i--) {
        comment.insert(0, lines[i]);
      }
      expect(comment.join('\n'),
          contains('https://learning.nspcc.org.uk/services/nspcc-helpline'),
          reason: 'the ruling puts the NSPCC Learning URL on the GB row');
    });

    test('a region-filled emergency number keeps the row hours and step', () {
      const row = LocalHelpNumbers(
        childProtection: '110',
        stepEn: 'and choose option 4',
        childProtectionHoursEn: '(open 24 hours)',
      );
      final n = resolveHelpNumbers(countryCode: 'ZZ', region: 'EU', table: {'ZZ': row});
      expect(n.emergency, '112');
      expect(n.stepEn, 'and choose option 4');
      expect(n.childProtectionHoursEn, '(open 24 hours)');
      expect(n.childProtectionClause(arabic: false),
          'call the child-protection line on \u2066110\u2069 (open 24 hours)');
    });

    // Hydrogen's item 4 (#727 review): the three-field assertions above cannot see a field the region branch drops.
    // The row already had value equality; the test simply never used it. A row is now compared whole, `crisisHoursAr`
    // included.
    test('the region branch returns the whole row, every field', () {
      const row = LocalHelpNumbers(
        childProtection: '110',
        crisis: '16000',
        stepEn: 'and choose option 4',
        stepAr: 'ثم اختر الرقم 4',
        childProtectionHoursEn: open24hEn,
        childProtectionHoursAr: open24hAr,
        crisisHoursEn: '(open Saturday to Thursday 08:00–18:00)',
        crisisHoursAr: '(يعمل من السبت إلى الخميس من 08:00 إلى 18:00)',
      );
      final filled = resolveHelpNumbers(countryCode: 'ZZ', region: 'EU', table: {'ZZ': row});
      expect(
        filled,
        const LocalHelpNumbers(
          emergency: '112',
          childProtection: '110',
          crisis: '16000',
          stepEn: 'and choose option 4',
          stepAr: 'ثم اختر الرقم 4',
          childProtectionHoursEn: open24hEn,
          childProtectionHoursAr: open24hAr,
          crisisHoursEn: '(open Saturday to Thursday 08:00–18:00)',
          crisisHoursAr: '(يعمل من السبت إلى الخميس من 08:00 إلى 18:00)',
        ),
        reason: 'a region fill changes the emergency number and nothing else',
      );
      // A row that already has an emergency number is returned untouched, not rebuilt.
      const complete = LocalHelpNumbers(emergency: '999', childProtection: '110');
      expect(resolveHelpNumbers(countryCode: 'ZZ', region: 'EU', table: {'ZZ': complete}), complete);
    });
  });

  // Hydrogen's blocking item 2 (#727 review). The table is the product: a wrong number is worse than none, and until
  // these rows existed a mutation of `AE` crisis or `KW` childProtection left every test green. Each `String?` here is
  // the cell itself, so a changed digit fails the row that names the country.
  group('the shipped rows are pinned cell by cell', () {
    test('every country row prints the numbers the table gives it, exactly', () {
      const expected = <String, List<String?>>{
        'AE': ['999', '116111', '800 4673'],
        'SA': ['999', '116111', '920033360'],
        'QA': ['999', '919', '16000'],
        'KW': ['112', '147', null],
        'BH': ['999', '998', null],
        'OM': ['9999', '1100', null],
        'JO': ['911', '110', null],
        'EG': ['122', '16000', null],
        'TR': ['112', '183', null],
        'US': ['911', '1-800-422-4453', '988'],
        'GB': ['999', '0808 800 5000', '116 123'],
      };
      expect(helpNumbersByCountry.keys.toSet(), expected.keys.toSet(),
          reason: 'a country was added or removed without a pin');
      for (final entry in expected.entries) {
        final row = helpNumbersByCountry[entry.key]!;
        expect(
          [row.emergency, row.childProtection, row.crisis],
          entry.value,
          reason: '${entry.key}: emergency, child-protection, crisis',
        );
      }
    });

    test('the hours and steps named in the review are pinned, per line and per language', () {
      final ae = helpNumbersByCountry['AE']!;
      expect(ae.crisisHoursEn, '(open daily 08:00–20:00; in Ramadan noon to midnight)');
      expect(ae.crisisHoursAr,
          '(يعمل يوميًا من 08:00 إلى 20:00، وفي رمضان من 12:00 إلى منتصف الليل)');
      expect(ae.childProtectionHoursEn, isNull, reason: 'the source states no hours');

      final sa = helpNumbersByCountry['SA']!;
      expect(sa.childProtectionHoursEn, '(open daily 07:00–23:00)');
      expect(sa.childProtectionHoursAr, '(يعمل يوميًا من 07:00 إلى 23:00)');
      expect(sa.crisisHoursEn, '(open 08:00–20:00; Saturdays 13:00–20:00)');

      final qa = helpNumbersByCountry['QA']!;
      expect([qa.stepEn, qa.stepAr], ['and choose option 4', 'ثم اختر الرقم 4']);
      expect(qa.crisisHoursEn, '(open Saturday to Thursday 08:00–18:00)');

      final gb = helpNumbersByCountry['GB']!;
      expect(gb.childProtectionHoursEn, '(open Monday to Friday 10:00–16:00)');
      expect(gb.crisisHoursEn, isNull, reason: 'the NHS page states no hours');

      final jo = helpNumbersByCountry['JO']!;
      expect(jo.childProtectionHoursEn,
          '(open Sunday to Thursday 08:00–20:00, Friday and Saturday 09:00–17:00)');
    });

    // Hydrogen's item 3: the 24-hour bracket is one sentence, and the two languages travel together.
    test('the 24-hour bracket is one sentence in each language, and they are never split', () {
      final fields = <String, List<String?>>{
        for (final entry in helpNumbersByCountry.entries)
          entry.key: [
            entry.value.emergencyHoursEn,
            entry.value.emergencyHoursAr,
            entry.value.childProtectionHoursEn,
            entry.value.childProtectionHoursAr,
            entry.value.crisisHoursEn,
            entry.value.crisisHoursAr,
          ],
      };
      for (final entry in fields.entries) {
        final f = entry.value;
        for (var pair = 0; pair < 6; pair += 2) {
          expect(f[pair] == null, f[pair + 1] == null,
              reason: '${entry.key}: a bracket in one language and not the other');
          if (f[pair] == open24hEn || f[pair + 1] == open24hAr) {
            expect(f[pair], open24hEn, reason: '${entry.key}: no second English spelling');
            expect(f[pair + 1], open24hAr, reason: '${entry.key}: no second Arabic spelling');
          }
        }
        // Nothing may say "24 hours" in prose: the bracket is the constant or it is absent.
        for (final text in f.whereType<String>()) {
          if (text.contains('24') || text.contains('على مدار')) {
            expect(text, anyOf(open24hEn, open24hAr),
                reason: '${entry.key}: a second spelling of the 24-hour bracket');
          }
        }
      }
    });
  });

  // Hydrogen's item 1: the sentence that makes the card safe is the emergency one, so no card may name a crisis or
  // child-protection line without saying what to do when the danger is immediate.
  group('every card that names a help line says what to do in immediate danger', () {
    test('the list of cards is the whole file, not a subset someone remembered', () {
      final source = File('lib/features/coach/coach_content.dart').readAsStringSync();
      final declared = RegExp(r'const _\w+ = CoachCard\(').allMatches(source).length;
      expect(allCoachCards.length, declared,
          reason: 'a card was added to the file without being added to allCoachCards');
    });

    test('each card that mentions {crisis} or {childProtection} also mentions {emergency}', () {
      for (final card in allCoachCards) {
        final texts = <String>[
          card.title,
          card.titleAr,
          card.body,
          card.bodyAr,
          ...card.tips,
          ...card.tipsAr,
        ];
        for (final text in texts) {
          final namesLine = text.contains('{crisis}') || text.contains('{childProtection}');
          if (!namesLine) continue;
          expect(text.contains('{emergency}'), isTrue,
              reason: 'this sentence names a help line but not the emergency number: $text');
        }
      }
    });
  });
}

/// The shipped self-harm card, reached through the public lookup so the test
/// fails if the card is ever detached from its category.
CoachCard _selfHarmCard() => coachCardFor('self_harm');
