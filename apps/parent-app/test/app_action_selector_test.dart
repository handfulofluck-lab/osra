import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:familyshield_parent/features/rules/rules_editor_screen.dart';
import 'package:familyshield_parent/l10n/l10n.dart';
import 'package:familyshield_parent/theme/app_theme.dart';

/// #931, the Arabic Language Bureau's block on this picker: «السماح», «حظر» and «حد زمني» break mid-word
/// as three segments at 320 px with 200 % text, and a word split in Arabic cursive is unreadable. The fix
/// is layout — the selector drops to the stacked buttons `appearance_screen.dart` uses when the three
/// labels cannot each hold one line. The wording is asserted as literals, because a row that compares the
/// screen to the getter feeding it passes whatever the ARB says (the #429 lesson).
void main() {
  const packageId = 'com.example.app';

  Future<void> pump(
    WidgetTester tester, {
    required double width,
    required double textScale,
    Locale locale = const Locale('ar'),
    TextDirection direction = TextDirection.rtl,
    String action = 'allow',
    ValueChanged<String>? onChanged,
  }) async {
    await tester.pumpWidget(MaterialApp(
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: AppTheme.light,
      home: Scaffold(
        body: Directionality(
          textDirection: direction,
          child: MediaQuery(
            data: MediaQueryData(size: Size(width, 640), textScaler: TextScaler.linear(textScale)),
            child: Center(
              child: SizedBox(
                width: width,
                child: AppActionSelector(
                  packageId: packageId,
                  action: action,
                  onChanged: onChanged ?? (_) {},
                ),
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  /// Every rendered label of `text` must occupy exactly one line and must not have been clipped or
  /// ellipsised to get there.
  void expectOneLineEach(WidgetTester tester, List<String> labels) {
    for (final label in labels) {
      final finder = find.text(label);
      expect(finder, findsOneWidget, reason: '«$label» is rendered');

      final text = tester.widget<Text>(finder);
      expect(text.maxLines, isNull, reason: '«$label» is not forced to one line with an ellipsis');
      expect(text.overflow ?? TextOverflow.clip, isNot(TextOverflow.ellipsis));

      final paragraph = tester.renderObject<RenderParagraph>(finder);
      final boxes = paragraph.getBoxesForSelection(TextSelection(baseOffset: 0, extentOffset: label.length));
      final lineTops = boxes.map((box) => box.top.roundToDouble()).toSet();
      expect(lineTops.length, 1, reason: '«$label» stays on one line — a break would split the word');
      expect(paragraph.size.width, greaterThan(0));
    }
  }

  testWidgets('320 px at 200 % falls back to the stacked buttons, one line per label', (tester) async {
    await pump(tester, width: 288, textScale: 2.0);

    expect(find.byKey(const ValueKey('appActionStacked-$packageId')), findsOneWidget);
    expect(find.byKey(const ValueKey('appActionSegments-$packageId')), findsNothing);
    expect(tester.takeException(), isNull, reason: 'no overflow at the smallest supported width');

    expectOneLineEach(tester, ['السماح', 'حظر', 'حد زمني']);
  });

  testWidgets('the stacked order is allow, block, time limit — top to bottom', (tester) async {
    await pump(tester, width: 288, textScale: 2.0);

    final allow = tester.getTopLeft(find.text('السماح')).dy;
    final block = tester.getTopLeft(find.text('حظر')).dy;
    final limit = tester.getTopLeft(find.text('حد زمني')).dy;
    expect(allow, lessThan(block));
    expect(block, lessThan(limit), reason: 'the order matches the segments read in the same direction');
  });

  testWidgets('a roomy width keeps the segmented button, the narrow one falls back', (tester) async {
    await pump(tester, width: 480, textScale: 1.0);
    expect(find.byKey(const ValueKey('appActionSegments-$packageId')), findsOneWidget);
    expect(find.byKey(const ValueKey('appActionStacked-$packageId')), findsNothing);
    expect(tester.takeException(), isNull);

    await pump(tester, width: 288, textScale: 2.0);
    expect(find.byKey(const ValueKey('appActionStacked-$packageId')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('no width or scale ever splits one of the three Arabic labels', (tester) async {
    // 288 is the inner width of a 320 px phone once the card padding is taken out — the smallest the app
    // supports. Every case must keep each label whole, whichever mode the selector picks.
    for (final width in [288.0, 320.0, 360.0, 420.0, 480.0]) {
      for (final scale in [1.0, 1.35, 2.0]) {
        await pump(tester, width: width, textScale: scale);
        expect(tester.takeException(), isNull, reason: 'no overflow at $width / $scale');
        expectOneLineEach(tester, ['السماح', 'حظر', 'حد زمني']);
      }
    }
  });

  testWidgets('the fallback reports the chosen action', (tester) async {
    final chosen = <String>[];
    await pump(tester, width: 288, textScale: 2.0, onChanged: chosen.add);

    await tester.tap(find.text('حظر'));
    await tester.pumpAndSettle();
    expect(chosen, ['block']);
  });

  testWidgets('English at 320 px / 200 % also falls back rather than overflowing', (tester) async {
    await pump(tester, width: 288, textScale: 2.0, locale: const Locale('en'), direction: TextDirection.ltr);

    expect(tester.takeException(), isNull);
    final stacked = find.byKey(const ValueKey('appActionStacked-$packageId'));
    final segmented = find.byKey(const ValueKey('appActionSegments-$packageId'));
    expect(stacked.evaluate().length + segmented.evaluate().length, 1, reason: 'exactly one selector is drawn');
  });
}
