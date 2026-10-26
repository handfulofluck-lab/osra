import 'dart:ui' show DartPluginRegistrant;

import 'package:dio/dio.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/models.dart';
import 'alert_notification.dart';
import 'local_notifier.dart';

/// What a wake did. Every path returns one; none throws, because a background
/// isolate that throws is a wake the OS may stop scheduling.
enum WakeOutcome {
  /// No `jwt` stored: the parent is signed out, so nothing is shown and nothing
  /// is fetched.
  signedOut,

  /// `/v1/alerts` answered 401. Deliberately terminal: the handler does **not**
  /// refresh the token (#360). A refresh from a background isolate would race
  /// the foreground refresh and could rotate a token under a live session; the
  /// next foreground launch refreshes normally and the alert is still there.
  unauthorized,

  /// The fetch failed (offline, 5xx, timeout). Nothing is shown, nothing is
  /// remembered, so the next wake tries again.
  failed,

  /// The page held nothing the parent has not already seen.
  nothingNew,

  /// Notifications were posted; [WakeOutcome] carries how many.
  shown,
}

/// The result of reading the alert page: a value, not an exception, because the
/// three outcomes mean genuinely different things to the parent.
@immutable
class AlertFetchOk {
  final List<Alert> alerts;
  const AlertFetchOk(this.alerts);
}

@immutable
class AlertFetchUnauthorized {
  const AlertFetchUnauthorized();
}

@immutable
class AlertFetchFailed {
  final String reason;
  const AlertFetchFailed(this.reason);
}

/// One background wake: read the session, read the alerts, show what is new.
///
/// Plan (§5 of the #360 decision):
/// 1. read `jwt` — no session, no fetch, no notification;
/// 2. `GET /v1/alerts?ack=false` — 401 ends the wake, never refreshes;
/// 3. [planNotifications] drops acked, duplicated and surplus rows;
/// 4. post one notification per alert, then persist the ids shown.
///
/// Step 4 is after step 3 on purpose: a wake that shows nothing must not write,
/// or a failed post would silence a real alert forever.
class BackgroundAlertWake {
  BackgroundAlertWake({
    required this.readJwt,
    required this.fetchAlerts,
    required this.notifier,
    required this.readShown,
    required this.writeShown,
  });

  final Future<String?> Function() readJwt;
  final Future<Object> Function(String jwt) fetchAlerts;
  final LocalNotifier notifier;
  final Future<Set<String>> Function() readShown;
  final Future<void> Function(Set<String>) writeShown;

  Future<WakeOutcome> run() async {
    String? jwt;
    try {
      jwt = await readJwt();
    } catch (_) {
      jwt = null;
    }
    if (jwt == null || jwt.isEmpty) return WakeOutcome.signedOut;

    final Object fetched;
    try {
      fetched = await fetchAlerts(jwt);
    } catch (e) {
      return WakeOutcome.failed;
    }

    final List<Alert> alerts;
    switch (fetched) {
      case AlertFetchOk(alerts: final page):
        alerts = page;
      case AlertFetchUnauthorized():
        return WakeOutcome.unauthorized;
      case AlertFetchFailed():
        return WakeOutcome.failed;
      case final Object other:
        throw ArgumentError('unexpected fetch result: $other');
    }

    final shown = await readShown();
    final plan = planNotifications(alerts: alerts, alreadyShown: shown);
    if (plan.isEmpty) return WakeOutcome.nothingNew;

    for (final alert in plan.toShow) {
      await notifier.show(VisibleAlert.from(alert));
    }

    final merged = {...shown, ...plan.remember};
    // Bounded so the store cannot grow without limit across months of wakes.
    final bounded = merged.length <= maxRememberedIds ? merged : merged.skip(merged.length - maxRememberedIds).toSet();
    await writeShown(bounded);
    return WakeOutcome.shown;
  }

  /// How many shown-alert ids are kept. A wake reads at most a page of alerts,
  /// so this only has to cover recent history, not everything ever shown.
  static const maxRememberedIds = 50;
}

/// The FCM background entry point (#360). Must be a top-level function with
/// `@pragma('vm:entry-point')`, or the release build tree-shakes it and wakes
/// stop arriving in production while working perfectly in debug.
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  WidgetsFlutterBinding.ensureInitialized();
  // Before any plugin is touched: the background isolate starts with no plugin
  // registrations, so secure storage and shared preferences would both fail.
  DartPluginRegistrant.ensureInitialized();

  await buildWake().run();
}

const _shownKey = 'push.shownAlertIds';

/// The real seams, in one place so [firebaseMessagingBackgroundHandler] stays a
/// three-line entry point and a test can build the same object.
BackgroundAlertWake buildWake() {
  const storage = FlutterSecureStorage();
  const base = String.fromEnvironment('API_BASE', defaultValue: '');
  final dio = Dio(BaseOptions(baseUrl: base));

  return BackgroundAlertWake(
    readJwt: () async {
      try {
        return await storage.read(key: 'jwt');
      } catch (_) {
        return null;
      }
    },
    fetchAlerts: (jwt) async {
      try {
        final res = await dio.get(
          '/v1/alerts',
          queryParameters: {'ack': 'false', 'limit': 20},
          options: Options(headers: {'Authorization': 'Bearer $jwt'}),
        );
        return AlertFetchOk(AlertsPage.fromJson(res.data).items);
      } on DioException catch (e) {
        if (e.response?.statusCode == 401) return const AlertFetchUnauthorized();
        return AlertFetchFailed(e.type.name);
      } catch (e) {
        return AlertFetchFailed(e.toString());
      }
    },
    notifier: FlutterLocalNotifier(),
    readShown: () async {
      final prefs = await SharedPreferences.getInstance();
      return (prefs.getStringList(_shownKey) ?? const []).toSet();
    },
    writeShown: (ids) async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_shownKey, ids.toList(growable: false));
    },
  );
}
