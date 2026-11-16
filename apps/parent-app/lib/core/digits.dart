/// The three digit forms the Bureaus accept (#771): `0–9`, Arabic-Indic `٠–٩`
/// (U+0660–U+0669) and Extended Arabic-Indic `۰–۹` (U+06F0–U+06F9).
///
/// An Arabic or Urdu keyboard types the latter two into a numeric field while
/// the product shows Western digits everywhere. Normalise before any check,
/// comparison, parse or request, so the same digits are one value whichever
/// keyboard typed them.
library;

/// Maps both Arabic digit families to `0–9`; every other character is unchanged.
String normalizeDigits(String value) {
  final buffer = StringBuffer();
  for (final rune in value.runes) {
    if (rune >= 0x0660 && rune <= 0x0669) {
      buffer.writeCharCode(0x30 + rune - 0x0660);
    } else if (rune >= 0x06F0 && rune <= 0x06F9) {
      buffer.writeCharCode(0x30 + rune - 0x06F0);
    } else {
      buffer.writeCharCode(rune);
    }
  }
  return buffer.toString();
}

/// Western or either Arabic family: what a numeric field may contain as typed.
final RegExp anyDigitPattern = RegExp(r'[0-9\u0660-\u0669\u06F0-\u06F9]');
