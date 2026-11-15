import 'package:familyshield_parent/core/digits.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('normalizeDigits (#771)', () {
    test('maps both Arabic digit families to Western digits', () {
      expect(normalizeDigits('٠١٢٣٤٥٦٧٨٩'), '0123456789');
      expect(normalizeDigits('۰۱۲۳۴۵۶۷۸۹'), '0123456789');
      expect(normalizeDigits('1٢3۴'), '1234');
      expect(normalizeDigits('4729'), '4729');
    });

    test('leaves anything that is not a digit alone', () {
      expect(normalizeDigits('a-ب.b،c'), 'a-ب.b،c');
      expect(normalizeDigits(''), '');
    });
  });

  group('anyDigitPattern (#771)', () {
    test('accepts all three families and refuses anything else', () {
      for (final rune in [0x30, 0x0661, 0x06F2]) {
        expect(anyDigitPattern.hasMatch(String.fromCharCode(rune)), isTrue);
      }
      expect(anyDigitPattern.hasMatch('½'), isFalse);
      expect(anyDigitPattern.hasMatch('a'), isFalse);
      expect(anyDigitPattern.hasMatch(''), isFalse);
    });
  });
}
