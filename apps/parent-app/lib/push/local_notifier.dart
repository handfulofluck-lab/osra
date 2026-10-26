import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../api/models.dart';

/// The visible half of an alert: what the parent reads on the lock screen.
///
/// Deliberately generic (#360 decision): the notification says an alert exists
/// and which child it concerns, never the child's content. The payload is the
/// alert id, so tapping it can open that alert once the app is up.
@immutable
class VisibleAlert {
  final String alertId;
  final String title;
  final String body;

  const VisibleAlert({required this.alertId, required this.title, required this.body});

  /// The one shape every producer uses, from one [Alert].
  ///
  /// The app is bilingual, and the background isolate has no `BuildContext` and
  /// no locale negotiation with the parent's last choice. It therefore posts the
  /// server's own text: the alert row is written in the family's language by the
  /// API, so what arrives is already the right language rather than an English
  /// template chosen here.
  factory VisibleAlert.from(Alert alert) => VisibleAlert(
        alertId: alert.id,
        title: alert.title.isEmpty ? 'OSRA' : alert.title,
        body: alert.body,
      );
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
