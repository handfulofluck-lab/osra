/// R-ID-3: human-readable time zones ("Dubai (GMT+4)") instead of raw IANA ids.
class TimezoneOption {
  final String id;
  final String city;
  final int offsetMinutes;

  const TimezoneOption({
    required this.id,
    required this.city,
    required this.offsetMinutes,
  });

  /// Formatted as `City (GMT+4)` or `City (GMT+5:30)` for screen display.
  String get label => '$city (${formatGmtOffset(offsetMinutes)})';

  bool matches(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return true;
    return city.toLowerCase().contains(q) ||
        formatGmtOffset(offsetMinutes).toLowerCase().contains(q) ||
        id.toLowerCase().contains(q);
  }
}

/// Curated launch-market zones sent as IANA ids to `PATCH /v1/family/me`.
const kCuratedTimezones = <TimezoneOption>[
  TimezoneOption(id: 'UTC', city: 'UTC', offsetMinutes: 0),
  TimezoneOption(id: 'Asia/Dubai', city: 'Dubai', offsetMinutes: 240),
  TimezoneOption(id: 'Asia/Riyadh', city: 'Riyadh', offsetMinutes: 180),
  TimezoneOption(id: 'Asia/Kuwait', city: 'Kuwait', offsetMinutes: 180),
  TimezoneOption(id: 'Asia/Qatar', city: 'Doha', offsetMinutes: 180),
  TimezoneOption(id: 'Asia/Bahrain', city: 'Manama', offsetMinutes: 180),
  TimezoneOption(id: 'Asia/Muscat', city: 'Muscat', offsetMinutes: 240),
  TimezoneOption(id: 'Asia/Amman', city: 'Amman', offsetMinutes: 180),
  TimezoneOption(id: 'Africa/Cairo', city: 'Cairo', offsetMinutes: 120),
  TimezoneOption(id: 'Europe/London', city: 'London', offsetMinutes: 0),
  TimezoneOption(id: 'Europe/Berlin', city: 'Berlin', offsetMinutes: 60),
  TimezoneOption(id: 'Europe/Paris', city: 'Paris', offsetMinutes: 60),
  TimezoneOption(id: 'Europe/Istanbul', city: 'Istanbul', offsetMinutes: 180),
  TimezoneOption(id: 'Asia/Karachi', city: 'Karachi', offsetMinutes: 300),
  TimezoneOption(id: 'Asia/Kolkata', city: 'Mumbai', offsetMinutes: 330),
  TimezoneOption(id: 'Asia/Jakarta', city: 'Jakarta', offsetMinutes: 420),
  TimezoneOption(id: 'Asia/Kuala_Lumpur', city: 'Kuala Lumpur', offsetMinutes: 480),
  TimezoneOption(id: 'Asia/Singapore', city: 'Singapore', offsetMinutes: 480),
  TimezoneOption(id: 'Asia/Tokyo', city: 'Tokyo', offsetMinutes: 540),
  TimezoneOption(id: 'America/New_York', city: 'New York', offsetMinutes: -300),
  TimezoneOption(id: 'America/Chicago', city: 'Chicago', offsetMinutes: -360),
  TimezoneOption(id: 'America/Los_Angeles', city: 'Los Angeles', offsetMinutes: -480),
  TimezoneOption(id: 'America/Argentina/Buenos_Aires', city: 'Buenos Aires', offsetMinutes: -180),
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
  return TimezoneOption(id: trimmed, city: segment, offsetMinutes: 0);
}

String formatTimezoneLabel(String id) {
  final known = _byId[id];
  if (known != null) return known.label;
  final trimmed = id.trim();
  if (trimmed.isEmpty) return kCuratedTimezones.first.label;
  return trimmed.split('/').last.replaceAll('_', ' ');
}

/// Picks the closest curated IANA zone for [offset] (defaulting to [DateTime.now().timeZoneOffset]).
String defaultDeviceTimezone([Duration? offset]) {
  final target = (offset ?? DateTime.now().timeZoneOffset).inMinutes;
  TimezoneOption? best;
  int? bestDelta;
  for (final tz in kCuratedTimezones) {
    final delta = (tz.offsetMinutes - target).abs();
    if (bestDelta == null || delta < bestDelta) {
      best = tz;
      bestDelta = delta;
      if (delta == 0 && tz.id != 'UTC') break;
    }
  }
  // Prefer a city zone when offset is 0 only if Europe/London; if exact UTC offset 0, UTC is first.
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
