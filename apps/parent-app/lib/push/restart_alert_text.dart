import 'package:intl/intl.dart';
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

import '../api/models.dart';
import '../core/digits.dart';
import '../core/ltr_isolate.dart';
import '../features/settings/timezone_catalog.dart';
import '../l10n/l10n.dart';

/// Issue #889: shared formatter for `device_restarted` alert bodies across the Alerts detail dialog
/// and push notifications (`VisibleAlert`), enforcing the Bureau date, rounding, isolation, and
/// Western-digit rules in the family's timezone:
/// - Same day as [now] in the family zone: `alertAtTime`.
/// - Yesterday in the family zone: `alertYesterdayAtTime`.
/// - Older dates: `alertOnDateAtTime`, omitting the year when it matches [now]'s year in that zone.
/// - `{device}` and `{time}` (`24h HH:mm` Western digits) wrapped with `ltrIsolate`.
/// - `< 1` min renders the `=0` clause; `1..119` min stay minutes; `>= 120` min round to the nearest
///   hour (`30m+` rounds up) in hours.
class RestartAlertText {
  final String model;
  final DateTime bootedAt;
  final int gapMinutes;
  final String? timeZone;
  final int? utcOffsetMinutes;

  const RestartAlertText({
    required this.model,
    required this.bootedAt,
    required this.gapMinutes,
    this.timeZone,
    this.utcOffsetMinutes,
  });

  /// Extracts restart fields from `metadata['bodyParams']` only when `bodyKey == 'alertBodyDeviceRestarted'`
  /// and required fields (`model`, `bootedAt`, `gapMinutes`) are present and non-empty. Never substitutes
  /// an English `'A phone'` placeholder, so Arabic UI falls back cleanly via `alertPushBodyGeneric`.
  static RestartAlertText? tryParse(Alert alert) {
    final bodyKey = alert.metadata['bodyKey']?.toString();
    if (bodyKey != 'alertBodyDeviceRestarted') {
      return null;
    }
    final rawParams = alert.metadata['bodyParams'];
    if (rawParams is! Map) return null;
    final source = Map<String, dynamic>.from(rawParams);

    final rawModel = source['model']?.toString().trim() ?? '';
    if (rawModel.isEmpty) return null;

    final rawBoot = source['bootedAt']?.toString();
    final bootedAt = rawBoot == null ? null : DateTime.tryParse(rawBoot);
    if (bootedAt == null) return null;

    final gapMinutes = _parseInt(source['gapMinutes']);
    if (gapMinutes == null) return null;

    final rawZone = source['timeZone']?.toString().trim();
    final timeZone = (rawZone != null && rawZone.isNotEmpty) ? rawZone : null;
    final utcOffsetMinutes = _parseInt(source['utcOffsetMinutes']);

    return RestartAlertText(
      model: rawModel,
      bootedAt: bootedAt,
      gapMinutes: gapMinutes < 0 ? 0 : gapMinutes,
      timeZone: timeZone,
      utcOffsetMinutes: utcOffsetMinutes,
    );
  }

  static int? _parseInt(Object? raw) => switch (raw) {
        int n => n,
        num n => n.round(),
        String s => int.tryParse(s),
        _ => null,
      };

  /// Formats [alert] in the parent's locale if valid restart parameters exist; otherwise null.
  static String? tryFormat(
    Alert alert, {
    required AppLocalizations l10n,
    required String localeName,
    DateTime? now,
  }) =>
      tryParse(alert)?.format(l10n, localeName: localeName, now: now);

  static bool _tzInitialized = false;

  static tz.Location? _resolveLocation(String? timeZone) {
    if (timeZone == null || timeZone.isEmpty) return null;
    if (!_tzInitialized) {
      tz_data.initializeTimeZones();
      _tzInitialized = true;
    }
    try {
      return tz.getLocation(timeZone);
    } catch (_) {
      return null;
    }
  }

  DateTime _inFamilyZone(DateTime instant, tz.Location? ianaLocation, TimezoneOption? knownTz) {
    if (ianaLocation != null) {
      final zoned = tz.TZDateTime.from(instant.toUtc(), ianaLocation);
      return DateTime.utc(zoned.year, zoned.month, zoned.day, zoned.hour, zoned.minute, zoned.second);
    }
    if (knownTz != null) {
      return instant.toUtc().add(Duration(minutes: knownTz.effectiveOffsetMinutes(instant)));
    }
    if (utcOffsetMinutes != null) {
      return instant.toUtc().add(Duration(minutes: utcOffsetMinutes!));
    }
    return instant.toLocal();
  }

  String format(AppLocalizations l10n, {required String localeName, DateTime? now}) {
    final ianaLocation = _resolveLocation(timeZone);
    final knownTz = (ianaLocation == null && timeZone != null) ? findKnownTimezone(timeZone!) : null;
    final familyBoot = _inFamilyZone(bootedAt, ianaLocation, knownTz);
    final familyNow = _inFamilyZone(now ?? DateTime.now(), ianaLocation, knownTz);
    // Pure Gregorian day step in UTC avoids any local phone DST anomaly on yesterday comparison.
    final yesterday = DateTime.utc(familyNow.year, familyNow.month, familyNow.day - 1);

    final isolatedDevice = ltrIsolate(model);
    final clock = normalizeDigits(DateFormat('HH:mm', 'en').format(familyBoot));
    final isolatedClock = ltrIsolate(clock);

    final String when;
    if (_sameDay(familyBoot, familyNow)) {
      when = l10n.alertAtTime(isolatedClock);
    } else if (_sameDay(familyBoot, yesterday)) {
      when = l10n.alertYesterdayAtTime(isolatedClock);
    } else {
      final isArabic = localeName.toLowerCase().startsWith('ar');
      final sameYear = familyBoot.year == familyNow.year;
      final pattern = isArabic ? (sameYear ? 'd MMMM' : 'd MMMM y') : (sameYear ? 'd MMM' : 'd MMM y');
      final dateLabel = normalizeDigits(DateFormat(pattern, isArabic ? 'ar' : 'en').format(familyBoot));
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
