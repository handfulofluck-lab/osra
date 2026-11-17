/// Daylight-saving rule for curated cities whose UTC offset changes seasonally.
enum TimezoneDstRule { none, eu, us, egypt }

/// R-ID-3: human-readable time zones ("Dubai (GMT+4)" / "دبي (GMT+4)")
/// instead of raw IANA ids.
class TimezoneOption {
  final String id;
  final String city;
  final String cityAr;
  final int offsetMinutes;
  final TimezoneDstRule dstRule;

  const TimezoneOption({
    required this.id,
    required this.city,
    String? cityAr,
    required this.offsetMinutes,
    this.dstRule = TimezoneDstRule.none,
  }) : cityAr = cityAr ?? city;

  /// Current UTC offset in minutes at [utcNow] (defaulting to current UTC time).
  int effectiveOffsetMinutes([DateTime? utcNow]) {
    if (dstRule == TimezoneDstRule.none) return offsetMinutes;
    final utc = (utcNow ?? DateTime.now()).toUtc();
    return _isDstActive(utc, dstRule, offsetMinutes) ? offsetMinutes + 60 : offsetMinutes;
  }

  /// Localized city label (`Dubai (GMT+4)` or `دبي (GMT+4)`).
  String labelFor(String languageCode, {DateTime? nowUtc}) {
    final name = languageCode.startsWith('ar') ? cityAr : city;
    return '$name (${formatGmtOffset(effectiveOffsetMinutes(nowUtc))})';
  }

  /// English formatted label (`City (GMT+4)`).
  String get label => labelFor('en');

  bool matches(String query, {DateTime? nowUtc}) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return true;
    return city.toLowerCase().contains(q) ||
        cityAr.toLowerCase().contains(q) ||
        formatGmtOffset(effectiveOffsetMinutes(nowUtc)).toLowerCase().contains(q) ||
        id.toLowerCase().contains(q);
  }
}

bool _isDstActive(DateTime utc, TimezoneDstRule rule, int standardOffsetMinutes) {
  final year = utc.year;
  switch (rule) {
    case TimezoneDstRule.none:
      return false;
    case TimezoneDstRule.eu:
      // EU DST: last Sunday of March 01:00 UTC to last Sunday of October 01:00 UTC.
      final start = _lastWeekdayOfMonth(year, DateTime.march, DateTime.sunday).add(const Duration(hours: 1));
      final end = _lastWeekdayOfMonth(year, DateTime.october, DateTime.sunday).add(const Duration(hours: 1));
      return !utc.isBefore(start) && utc.isBefore(end);
    case TimezoneDstRule.us:
      // US DST: second Sunday of March 02:00 standard time to first Sunday of November 01:00 standard time.
      final stdHours = standardOffsetMinutes ~/ 60;
      final start = _nthWeekdayOfMonth(year, DateTime.march, DateTime.sunday, 2)
          .add(Duration(hours: 2 - stdHours));
      final end = _nthWeekdayOfMonth(year, DateTime.november, DateTime.sunday, 1)
          .add(Duration(hours: 1 - stdHours));
      return !utc.isBefore(start) && utc.isBefore(end);
    case TimezoneDstRule.egypt:
      // Egypt DST: 00:00 EET (22:00 UTC Thu) on last Friday of April to 24:00 EEST (21:00 UTC) on last Thursday of October.
      final start = _lastWeekdayOfMonth(year, DateTime.april, DateTime.friday).subtract(const Duration(hours: 2));
      final end = _lastWeekdayOfMonth(year, DateTime.october, DateTime.thursday).add(const Duration(hours: 21));
      return !utc.isBefore(start) && utc.isBefore(end);
  }
}

DateTime _lastWeekdayOfMonth(int year, int month, int weekday) {
  final nextMonth = month == 12 ? DateTime.utc(year + 1, 1, 1) : DateTime.utc(year, month + 1, 1);
  var day = nextMonth.subtract(const Duration(days: 1));
  while (day.weekday != weekday) {
    day = day.subtract(const Duration(days: 1));
  }
  return day;
}

DateTime _nthWeekdayOfMonth(int year, int month, int weekday, int n) {
  var day = DateTime.utc(year, month, 1);
  while (day.weekday != weekday) {
    day = day.add(const Duration(days: 1));
  }
  return day.add(Duration(days: (n - 1) * 7));
}

/// Curated launch-market zones sent as IANA ids to `PATCH /v1/family/me`.
const kCuratedTimezones = <TimezoneOption>[
  TimezoneOption(id: 'UTC', city: 'UTC', cityAr: 'UTC', offsetMinutes: 0),
  TimezoneOption(id: 'Asia/Dubai', city: 'Dubai', cityAr: 'دبي', offsetMinutes: 240),
  TimezoneOption(id: 'Asia/Riyadh', city: 'Riyadh', cityAr: 'الرياض', offsetMinutes: 180),
  TimezoneOption(id: 'Asia/Kuwait', city: 'Kuwait', cityAr: 'الكويت', offsetMinutes: 180),
  TimezoneOption(id: 'Asia/Qatar', city: 'Doha', cityAr: 'الدوحة', offsetMinutes: 180),
  TimezoneOption(id: 'Asia/Bahrain', city: 'Manama', cityAr: 'المنامة', offsetMinutes: 180),
  TimezoneOption(id: 'Asia/Muscat', city: 'Muscat', cityAr: 'مسقط', offsetMinutes: 240),
  TimezoneOption(id: 'Asia/Amman', city: 'Amman', cityAr: 'عمّان', offsetMinutes: 180),
  TimezoneOption(id: 'Africa/Cairo', city: 'Cairo', cityAr: 'القاهرة', offsetMinutes: 120, dstRule: TimezoneDstRule.egypt),
  TimezoneOption(id: 'Europe/London', city: 'London', cityAr: 'لندن', offsetMinutes: 0, dstRule: TimezoneDstRule.eu),
  TimezoneOption(id: 'Europe/Berlin', city: 'Berlin', cityAr: 'برلين', offsetMinutes: 60, dstRule: TimezoneDstRule.eu),
  TimezoneOption(id: 'Europe/Paris', city: 'Paris', cityAr: 'باريس', offsetMinutes: 60, dstRule: TimezoneDstRule.eu),
  TimezoneOption(id: 'Europe/Istanbul', city: 'Istanbul', cityAr: 'إسطنبول', offsetMinutes: 180),
  TimezoneOption(id: 'Asia/Karachi', city: 'Karachi', cityAr: 'كراتشي', offsetMinutes: 300),
  TimezoneOption(id: 'Asia/Kolkata', city: 'Mumbai', cityAr: 'مومباي', offsetMinutes: 330),
  TimezoneOption(id: 'Asia/Jakarta', city: 'Jakarta', cityAr: 'جاكرتا', offsetMinutes: 420),
  TimezoneOption(id: 'Asia/Kuala_Lumpur', city: 'Kuala Lumpur', cityAr: 'كوالالمبور', offsetMinutes: 480),
  TimezoneOption(id: 'Asia/Singapore', city: 'Singapore', cityAr: 'سنغافورة', offsetMinutes: 480),
  TimezoneOption(id: 'Asia/Tokyo', city: 'Tokyo', cityAr: 'طوكيو', offsetMinutes: 540),
  TimezoneOption(id: 'America/New_York', city: 'New York', cityAr: 'نيويورك', offsetMinutes: -300, dstRule: TimezoneDstRule.us),
  TimezoneOption(id: 'America/Chicago', city: 'Chicago', cityAr: 'شيكاغو', offsetMinutes: -360, dstRule: TimezoneDstRule.us),
  TimezoneOption(id: 'America/Los_Angeles', city: 'Los Angeles', cityAr: 'لوس أنجلوس', offsetMinutes: -480, dstRule: TimezoneDstRule.us),
  TimezoneOption(id: 'America/Argentina/Buenos_Aires', city: 'Buenos Aires', cityAr: 'بوينس آيرس', offsetMinutes: -180),
];

final Map<String, TimezoneOption> _byId = {
  for (final tz in kCuratedTimezones) tz.id: tz,
};

String formatGmtOffset(int offsetMinutes) {
  if (offsetMinutes == 0) return 'GMT+0';
  final sign = offsetMinutes > 0 ? '+' : '-';
  final abs = offsetMinutes.abs();
  final hours = abs ~/ 60;
  final mins = abs % 60;
  if (mins == 0) return 'GMT$sign$hours';
  return 'GMT$sign$hours:${mins.toString().padLeft(2, '0')}';
}

/// Converts any IANA id (including server-returned values outside [kCuratedTimezones])
/// into a human-friendly label without slashes or underscores.
TimezoneOption timezoneOptionFor(String id) {
  final known = _byId[id];
  if (known != null) return known;
  final trimmed = id.trim();
  if (trimmed.isEmpty) return kCuratedTimezones.first;
  final segment = trimmed.split('/').last.replaceAll('_', ' ');
  return TimezoneOption(id: trimmed, city: segment, cityAr: segment, offsetMinutes: 0);
}

String formatTimezoneLabel(String id, {String languageCode = 'en', DateTime? nowUtc}) {
  final known = _byId[id];
  if (known != null) return known.labelFor(languageCode, nowUtc: nowUtc);
  final trimmed = id.trim();
  if (trimmed.isEmpty) return kCuratedTimezones.first.labelFor(languageCode, nowUtc: nowUtc);
  return trimmed.split('/').last.replaceAll('_', ' ');
}

/// Picks the closest curated IANA zone for [offset] (defaulting to [DateTime.now().timeZoneOffset]).
String defaultDeviceTimezone([Duration? offset, DateTime? nowUtc]) {
  final target = (offset ?? DateTime.now().timeZoneOffset).inMinutes;
  TimezoneOption? best;
  int? bestDelta;
  for (final tz in kCuratedTimezones) {
    final delta = (tz.effectiveOffsetMinutes(nowUtc) - target).abs();
    if (bestDelta == null || delta < bestDelta) {
      best = tz;
      bestDelta = delta;
      if (delta == 0 && tz.id != 'UTC') break;
    }
  }
  return (best ?? kCuratedTimezones.first).id;
}

/// Returns all options with [currentId] pinned first when set.
List<TimezoneOption> orderedTimezones(String? currentId) {
  if (currentId == null || currentId.trim().isEmpty) {
    return kCuratedTimezones;
  }
  final current = timezoneOptionFor(currentId);
  return [
    current,
    for (final tz in kCuratedTimezones)
      if (tz.id != current.id) tz,
  ];
}
