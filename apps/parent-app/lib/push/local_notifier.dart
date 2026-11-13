import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../api/models.dart';
import '../l10n/l10n.dart';

/// Issue #672: how old the SOS fix is, as the notification says it. A fix under a minute old reads
/// "1 min ago": rounding up is the safe direction — a parent must never be told a fix is fresher than it is.
String sosFixAgeText(AppLocalizations l10n, Alert alert, AlertFix fix, DateTime now) {
  final age = fix.ageAt(now, alertCreatedAt: alert.createdAt) ?? Duration.zero;
  final minutes = age.inMinutes;
  if (minutes < 60) return l10n.alertFixAgeMinutes(minutes < 1 ? 1 : minutes);
  return l10n.alertFixAgeHours(age.inHours);
}

/// The visible half of an alert: what the parent reads on the lock screen.
///
/// Deliberately generic (#360 decision 3): the notification says an alert
/// exists and which *kind* it is, never the child's content. The server writes
/// its own titles in English — `YouTube video flagged: <video title>`,
/// `Social concern in <app>` — so showing `alert.title` verbatim would leak a
/// search query or a video title onto a locked screen, in English, to an Arabic
/// family (#395 review).
///
/// **The one exception is an SOS with a fix (#672)**: "near 25.276900, 51.521100, 3 min ago", from the
/// app's own strings, because a parent who gets an SOS needs "where" in the same notification and the push
/// payload carries no text by #410. Coordinates only — there is no reverse geocoder — and the age is said
/// out loud, so an old fix is never presented as a live one. [now] is a parameter so the age is testable.
@immutable
class VisibleAlert {
  final String alertId;
  final String title;
  final String body;

  const VisibleAlert({required this.alertId, required this.title, required this.body});

  /// The one shape every producer uses, from one [Alert].
  ///
  /// The background isolate has no `BuildContext`, so the caller resolves the
  /// parent's stored locale and passes the matching [l10n] in. The title is the
  /// app's own translated **category** title ([alertTitleFor]), never the
  /// server's text, and the body is one generic sentence: the details are one
  /// tap away in the app, where the content is already behind the parent's PIN.
  factory VisibleAlert.from(Alert alert, {required AppLocalizations l10n, required bool isEnglish, DateTime? now}) {
    final fix = alert.category == 'sos' ? alert.location : null;
    final body = fix == null
        ? l10n.alertPushBodyGeneric
        : l10n.alertSosWhere(fix.coordsText, sosFixAgeText(l10n, alert, fix, now ?? DateTime.now()));
    return VisibleAlert(
      alertId: alert.id,
      title: l10n.alertTitleFor(alert.category, alert.title, isEnglish: isEnglish),
      body: body,
    );
  }
}

/// Posts a notification. A seam, so the wake's decisions are testable without a
/// platform channel and so a build without the plugin reports nothing.
abstract class LocalNotifier {
  Future<void> show(VisibleAlert alert);
}

/// Nothing is shown. Used where the plugin cannot post (a unit test, a target
/// with no notification support) so [planNotifications] can still be exercised.
class UnavailableNotifier implements LocalNotifier {
  const UnavailableNotifier();

  @override
  Future<void> show(VisibleAlert alert) async {}
}

/// `flutter_local_notifications`, one channel for alerts.
///
/// A stable notification id per alert ([_idFor]) matters: a redelivered wake
/// replaces the existing notification instead of stacking a second copy, so the
/// duplicate rule in `planNotifications` is not the only thing standing between
/// the parent and a wall of identical rows.
class FlutterLocalNotifier implements LocalNotifier {
  FlutterLocalNotifier({FlutterLocalNotificationsPlugin? plugin}) : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  static const channelId = 'osra_alerts';
  static const channelName = 'OSRA alerts';
  static const channelDescription = 'Lock screen, screen time and safety alerts from your family';

  final FlutterLocalNotificationsPlugin _plugin;
  bool _ready = false;

  Future<void> _ensureInitialised() async {
    if (_ready) return;
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        iOS: DarwinInitializationSettings(
          // The token registration already asked for permission (#360, #391).
          // Asking again here would be a second prompt from a background
          // isolate, where no UI exists to answer it.
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false,
        ),
      ),
    );
    _ready = true;
  }

  @override
  Future<void> show(VisibleAlert alert) async {
    await _ensureInitialised();
    await _plugin.show(
      id: _idFor(alert.alertId),
      title: alert.title,
      body: alert.body,
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          channelId,
          channelName,
          channelDescription: channelDescription,
          importance: Importance.high,
          priority: Priority.high,
          // No content on a locked screen: the alert title can name a category,
          // and the OS draws that even when the device is locked (#395 review).
          visibility: NotificationVisibility.private,
        ),
        iOS: DarwinNotificationDetails(),
      ),
      payload: alert.alertId,
    );
  }

  /// A stable 31-bit id from the alert id, so the same alert always lands on the
  /// same notification slot.
  static int _idFor(String alertId) {
    var hash = 0;
    for (final unit in alertId.codeUnits) {
      hash = (hash * 31 + unit) & 0x7fffffff;
    }
    return hash;
  }
}
