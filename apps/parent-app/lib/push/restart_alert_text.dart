import 'package:intl/intl.dart';

import '../api/models.dart';
import '../core/digits.dart';
import '../core/ltr_isolate.dart';
import '../l10n/l10n.dart';

/// Issue #889: shared formatter for `device_restarted` alert bodies across the Alerts detail dialog
/// and push notifications (`VisibleAlert`), enforcing the Bureau date, rounding, isolation, and
/// Western-digit rules:
/// - Same day as [now] in local time: `alertAtTime`.
/// - Yesterday in local time: `alertYesterdayAtTime`.
/// - Older dates: `alertOnDateAtTime`, omitting the year when it matches [now]'s year.
/// - `{device}` and `{time}` (`24h HH:mm` Western digits) wrapped with `ltrIsolate`.
/// - `< 1` min renders the `=0` clause; `1..119` min stay minutes; `>= 120` min round to the nearest
///   hour (`30m+` rounds up) in hours.
class RestartAlertText {
  final String model;
  final DateTime bootedAt;
  final int gapMinutes;

  const RestartAlertText({
    required this.model,
    required this.bootedAt,
    required this.gapMinutes,
  });

  /// Extracts restart fields from `metadata['bodyParams']` (when validated `bodyKey` matches) or
  /// falls back to top-level `metadata` fields. Returns null when required fields are absent/invalid.
  static RestartAlertText? tryParse(Alert alert) {
    final bodyKey = alert.metadata['bodyKey']?.toString();
    if (bodyKey != 'alertBodyDeviceRestarted' && alert.category != 'device_restarted') {
      return null;
    }
    final rawParams = alert.metadata['bodyParams'];
    final source = rawParams is Map ? Map<String, dynamic>.from(rawParams) : alert.metadata;

    final rawBoot = (source['bootedAt'] ?? alert.metadata['bootedAt'])?.toString();
    final bootedAt = rawBoot == null ? null : DateTime.tryParse(rawBoot);
    if (bootedAt == null) return null;

    final rawGap = source['gapMinutes'] ?? alert.metadata['gapMinutes'];
    final gapMinutes = switch (rawGap) {
      int n => n,
      num n => n.round(),
      String s => int.tryParse(s),
      _ => null,
    };
    if (gapMinutes == null) return null;

    final rawModel = (source['model'] ?? alert.metadata['model'])?.toString().trim() ?? '';
    final model = rawModel.isNotEmpty ? rawModel : 'A phone';
    return RestartAlertText(
      model: model,
      bootedAt: bootedAt,
      gapMinutes: gapMinutes < 0 ? 0 : gapMinutes,
    );
  }

  /// Formats [alert] in the parent's locale if valid restart parameters exist; otherwise null.
  static String? tryFormat(
    Alert alert, {
    required AppLocalizations l10n,
    required String localeName,
    DateTime? now,
  }) =>
      tryParse(alert)?.format(l10n, localeName: localeName, now: now);

  String format(AppLocalizations l10n, {required String localeName, DateTime? now}) {
    final localBoot = bootedAt.toLocal();
    final localNow = (now ?? DateTime.now()).toLocal();
    final yesterday = DateTime(localNow.year, localNow.month, localNow.day - 1);

    final isolatedDevice = ltrIsolate(model);
    final clock = normalizeDigits(DateFormat('HH:mm', 'en').format(localBoot));
    final isolatedClock = ltrIsolate(clock);

    final String when;
    if (_sameDay(localBoot, localNow)) {
      when = l10n.alertAtTime(isolatedClock);
    } else if (_sameDay(localBoot, yesterday)) {
      when = l10n.alertYesterdayAtTime(isolatedClock);
    } else {
      final isArabic = localeName.toLowerCase().startsWith('ar');
      final sameYear = localBoot.year == localNow.year;
      final pattern = isArabic ? (sameYear ? 'd MMMM' : 'd MMMM y') : (sameYear ? 'd MMM' : 'd MMM y');
      final dateLabel = normalizeDigits(DateFormat(pattern, isArabic ? 'ar' : 'en').format(localBoot));
      when = l10n.alertOnDateAtTime(dateLabel, isolatedClock);
    }

    if (gapMinutes < 120) {
      return l10n.alertDeviceRestartedBodyMinutes(isolatedDevice, when, gapMinutes);
    }
    final hours = (gapMinutes + 30) ~/ 60;
    return l10n.alertDeviceRestartedBodyHours(isolatedDevice, when, hours);
  }

  static bool _sameDay(DateTime a, DateTime b) => a.year == b.year && a.month == b.month && a.day == b.day;
}
