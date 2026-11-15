import 'package:flutter/services.dart';

import 'digit_normalization.dart';

export 'digit_normalization.dart';

class DigitInputFormatter extends TextInputFormatter {
  const DigitInputFormatter();

  @override
  TextEditingValue formatEditUpdate(
      TextEditingValue oldValue, TextEditingValue newValue) {
    final input = newValue.text;
    final normalized = normalizeDigits(input);
    if (normalized == null) return oldValue;
    int mapOffset(int offset) {
      if (offset < 0) return normalized.length;
      var outputOffset = 0;
      var inputOffset = 0;
      for (final codePoint in input.runes) {
        if (inputOffset >= offset) break;
        if (codePoint >= 0x30 && codePoint <= 0x39 ||
            codePoint >= 0x660 && codePoint <= 0x669 ||
            codePoint >= 0x6f0 && codePoint <= 0x6f9) {
          outputOffset++;
        }
        inputOffset += codePoint > 0xffff ? 2 : 1;
      }
      return outputOffset;
    }

    final start = mapOffset(newValue.selection.start);
    final end = mapOffset(newValue.selection.end);
    return newValue.copyWith(
      text: normalized,
      selection: TextSelection(baseOffset: start, extentOffset: end),
      composing: TextRange.empty,
    );
  }
}
