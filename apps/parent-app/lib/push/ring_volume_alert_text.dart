import '../api/models.dart';
import '../core/digits.dart';
import '../l10n/l10n.dart';

/// osra-security#42 / #944: formats the parent-visible `ring_volume` alert body in EN or AR using
/// the Bureau-approved copy (UI/UX 7015553552, Arabic Language Bureau 7015600248):
/// - Wraps `{child}` in a Unicode first-strong isolate (`U+2068` ... `U+2069`) in BOTH languages so
///   an Arabic child name inside English or a Latin child name inside Arabic keeps its direction.
/// - Normalizes `{count}` to Western ASCII digits (`0-9`) in both languages (#762).
class RingVolumeAlertText {
  const RingVolumeAlertText._();

  static int? parseCount(Alert alert) {
    final raw = alert.metadata['count'];
    final fromMeta = switch (raw) {
      int n => n,
      num n => n.round(),
      String s => int.tryParse(s.trim()),
      _ => null,
    };
    if (fromMeta != null) return fromMeta >= 1 ? fromMeta : null;
    if (alert.attemptCount >= 1) return alert.attemptCount;
    return null;
  }

  static String? tryFormat(
    Alert alert, {
    required AppLocalizations l10n,
    String? childName,
  }) {
    final count = parseCount(alert);
    if (count == null) return null;
    final trimmedChild = childName?.trim() ?? '';
    final fromMetaChild = alert.metadata['childName']?.toString().trim() ?? '';
    final resolvedChild = trimmedChild.isNotEmpty
        ? trimmedChild
        : (fromMetaChild.isNotEmpty ? fromMetaChild : l10n.childFallback);
    final isolatedChild = '\u{2068}$resolvedChild\u{2069}';
    return normalizeDigits(l10n.alertRingVolumeBody(isolatedChild, count));
  }
}
