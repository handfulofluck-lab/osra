String? normalizeDigits(String input) {
  final normalized = StringBuffer();
  for (final codePoint in input.runes) {
    if (codePoint >= 0x30 && codePoint <= 0x39) {
      normalized.writeCharCode(codePoint);
    } else if (codePoint >= 0x660 && codePoint <= 0x669) {
      normalized.writeCharCode(codePoint - 0x660 + 0x30);
    } else if (codePoint >= 0x6f0 && codePoint <= 0x6f9) {
      normalized.writeCharCode(codePoint - 0x6f0 + 0x30);
    } else if (codePoint != 0x20 &&
        codePoint != 0x200e &&
        codePoint != 0x200f &&
        codePoint != 0x61c) {
      return null;
    }
  }
  return normalized.toString();
}
