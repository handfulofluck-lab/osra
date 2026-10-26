import 'package:flutter/foundation.dart';

import '../api/models.dart';

/// What one background wake should put on the lock screen (#360, roadmap 3.9).
///
/// The push payload is data-only (`{ "w": "1" }`): it says "an alert exists",
/// not what the alert says, because the server must not put a child's data in
/// a payload an OS service can see. So the wake reads the alerts, and this
/// decides what the parent has not already been shown.
@immutable
class NotificationPlan {
  /// The alerts to show, **oldest first**: the last call wins the top of the
  /// notification shade, so the newest alert is the one the parent sees first.
  final List<Alert> toShow;

  /// The ids to remember as shown. Every fresh id, not only the ones in
  /// [toShow]: an id dropped by [max] must not come back on a later wake.
  final List<String> remember;

  const NotificationPlan({required this.toShow, required this.remember});

  bool get isEmpty => toShow.isEmpty;

  static const empty = NotificationPlan(toShow: [], remember: []);
}

/// Which alerts a wake shows, given the page it read and the ids it has
/// already shown.
///
/// Three exclusions, each for a different reason:
/// - **acknowledged** — the parent has already seen it in the app; a
///   notification for it is noise on a lock screen.
/// - **already shown** — this is the duplicate rule. A wake can arrive twice
///   (a redelivered message, a retry, a second device), and re-posting the same
///   alert would train the parent to dismiss without reading.
/// - **beyond [max]** — a backlog must not turn into a wall of notifications.
///   The oldest are dropped, because the newest is the one that matters now.
///
/// Pure on purpose: no plugin, no clock, no I/O, so the JVM suite holds every
/// row without a phone.
NotificationPlan planNotifications({
  required List<Alert> alerts,
  required Set<String> alreadyShown,
  int max = 5,
}) {
  final fresh = <Alert>[];
  final seen = <String>{};
  for (final alert in alerts) {
    if (alert.acknowledged) continue;
    if (alreadyShown.contains(alert.id)) continue;
    if (!seen.add(alert.id)) continue;
    fresh.add(alert);
  }

  // Oldest first, with an unknown time treated as the oldest: a null date is a
  // parse gap, and putting it last would make it win the shade for no reason.
  fresh.sort((a, b) {
    final at = a.createdAt;
    final bt = b.createdAt;
    if (at == null && bt == null) return a.id.compareTo(b.id);
    if (at == null) return -1;
    if (bt == null) return 1;
    return at.compareTo(bt);
  });

  final keep = fresh.length <= max ? fresh : fresh.sublist(fresh.length - max);
  return NotificationPlan(
    toShow: List.unmodifiable(keep),
    // Every fresh id, not only the ones shown (#395 review). Remembering the
    // cap's leftovers is what stops a backlog from dribbling back out over later
    // wakes, out of order and late: with 8 waiting, the first wake shows the
    // newest 5 and the next one must not treat the other 3 as new.
    remember: List.unmodifiable(fresh.map((a) => a.id)),
  );
}
