import 'digits.dart';
import 'ltr_isolate.dart';

final _directionMarks =
    RegExp(r'[\u061C\u200B\u200E\u200F\u202A-\u202E\u2066-\u2069]');
final _phoneLabel = RegExp(r'^\+?[0-9().\s-]+$');
final _nonDigit = RegExp(r'[^0-9]');

/// The visible sender label for a parent-only Social surface.
String? socialSenderDisplayName(String? raw) {
  final label = raw?.replaceAll(_directionMarks, '').trim() ?? '';
  if (label.isEmpty) return null;
  final normalized = normalizeDigits(label);
  if (_phoneLabel.hasMatch(normalized)) {
    final digits = normalized.replaceAll(_nonDigit, '');
    if (digits.isNotEmpty) {
      final suffix =
          digits.length > 4 ? ' ${digits.substring(digits.length - 4)}' : '';
      return ltrIsolate('••••$suffix');
    }
  }
  return label;
}
