import 'package:familyshield_parent/core/digits.dart';
import 'package:familyshield_parent/features/pairing/pair_qr_payload.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('normalizeDigits (#771)', () {
    test('maps both approved digit sets, mixed input and approved marks/spaces', () {
      expect(normalizeDigits('٠١٢٣٤٥٦'), '0123456');
      expect(normalizeDigits('۱۲۳۴۵۶'), '123456');
      expect(normalizeDigits('٠1٢2۳3۴4۵5۶6'), '012233445566');
      expect(normalizeDigits('1٢3۴ 5\u200E6\u200F7\u061C8'), '12345678');
    });

    test('rejects full-width digits, other scripts and every other character', () {
      for (final value in ['１２３４５６', '\u09E7\u09E8\u09E9\u09EA\u09EB\u09EC', '\u0967\u0968\u0969\u096A\u096B\u096C', '12a456', '123\n456', '123\t456']) {
        expect(normalizeDigits(value), isNull);
      }
    });
  });

  group('DigitInputFormatter', () {
    testWidgets('accepts sequential Arabic-Indic input and puts the cursor after a stripped mark', (tester) async {
      final controller = TextEditingController();
      final focus = FocusNode();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: TextField(
            controller: controller,
            focusNode: focus,
            inputFormatters: [DigitInputFormatter()],
          ),
        ),
      ));
      focus.requestFocus();

      await tester.enterText(find.byType(TextField), '٠');
      expect(controller.text, '0');
      expect(controller.selection.baseOffset, 1);
      await tester.enterText(find.byType(TextField), '0١');
      expect(controller.text, '01');
      expect(controller.selection.baseOffset, 2);
      await tester.enterText(find.byType(TextField), '01\u200E');
      expect(controller.text, '01');
      expect(controller.selection.baseOffset, 2);
      await tester.enterText(find.byType(TextField), '01\u200E٢');
      expect(controller.text, '012');
      expect(controller.selection.baseOffset, 3);
      controller.dispose();
      focus.dispose();
    });

    test('keeps the cursor beside the same digit when a mark is removed before it', () {
      const formatter = DigitInputFormatter();
      final formatted = formatter.formatEditUpdate(
        TextEditingValue.empty,
        const TextEditingValue(text: '0\u200E1', selection: TextSelection.collapsed(offset: 2)),
      );
      expect(formatted.text, '01');
      expect(formatted.selection.baseOffset, 1);
    });

    test('rejects other characters instead of allowing a different digit set', () {
      const formatter = DigitInputFormatter();
      const before = TextEditingValue(text: '01', selection: TextSelection.collapsed(offset: 2));
      final rejected = formatter.formatEditUpdate(
        before,
        const TextEditingValue(text: '１２', selection: TextSelection.collapsed(offset: 2)),
      );
      expect(rejected.text, '01');
      expect(rejected.selection.baseOffset, 2);
    });
  });

  group('PairQrPayload', () {
    test('normalizes the code before encoding, and rejects full-width digits', () {
      final payload = PairQrPayload(code: '١٢٣٤٥٦', apiBaseUrl: 'https://unit.test');
      expect(payload.encode(), contains('code=123456'));
      expect(PairQrPayload.decode('osra://pair?v=1&code=١٢٣٤٥٦&host=https%3A%2F%2Funit.test').code, '123456');
      expect(
        () => PairQrPayload(code: '１２３４５６', apiBaseUrl: 'https://unit.test').encode(),
        throwsFormatException,
      );
    });
  });
}
