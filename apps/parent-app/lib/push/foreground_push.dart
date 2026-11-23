import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform, visibleForTesting;
import 'package:shared_preferences/shared_preferences.dart';

import 'background_push.dart';
import 'notification_tap.dart';

const _shownAlertIdsKey = 'push.shownAlertIds';

/// #1028: Returns true when iOS itself will render a visible foreground banner
/// and sound for this push payload, so the client must NOT post a second local
/// notification for the same alert.
bool isPresentedNativelyInForeground({
  required bool isApplePlatform,
  required bool nativeForegroundPresentationEnabled,
  required bool hasNotificationPayload,
}) =>
    isApplePlatform && nativeForegroundPresentationEnabled && hasNotificationPayload;

/// #1028: Routes a tap on a native FCM/APNs notification into [NotificationTapController]
/// so GoRouter opens `/alerts/:id` (matching local-notification taps from #972).
void recordFcmNotificationTap(
  Map<String, dynamic> data, [
  NotificationTapController? controller,
]) {
  final alertId = data['alertId']?.toString();
  if (alertId == null || alertId.trim().isEmpty) return;
  (controller ?? notificationTapController).recordTap(alertId);
}

/// #1028: Coordinates foreground FCM wakes through the exact same
/// [BackgroundAlertWake] pipeline (`toVisible` -> `LocalNotifier.show` ->
/// `writeShown` with shared [AlertPresentationClaimer]) used by the background
/// handler, while selecting a single presenter on iOS when the server already
/// sent a visible APNs alert (`fcm.ts`).
class ForegroundPushBridge {
  ForegroundPushBridge({
    required Future<WakeOutcome> Function() runWake,
    this.isApplePlatform = false,
    this.nativeForegroundPresentationEnabled = false,
    Future<void> Function(String alertId)? markAlertIdShown,
  })  : _runWake = runWake,
        _markAlertIdShown = markAlertIdShown ?? _persistShownAlertId;

  final Future<WakeOutcome> Function() _runWake;
  final bool isApplePlatform;
  final bool nativeForegroundPresentationEnabled;
  final Future<void> Function(String alertId) _markAlertIdShown;
  Future<WakeOutcome> _queue = Future<WakeOutcome>.value(WakeOutcome.nothingNew);

  /// Handles one foreground push event. Never throws, matching [BackgroundAlertWake.run].
  Future<WakeOutcome> handleMessage({
    bool hasNotificationPayload = false,
    Map<String, dynamic> data = const {},
  }) {
    final next = _queue.then((_) async {
      try {
        if (isPresentedNativelyInForeground(
          isApplePlatform: isApplePlatform,
          nativeForegroundPresentationEnabled: nativeForegroundPresentationEnabled,
          hasNotificationPayload: hasNotificationPayload,
        )) {
          // Single presenter on iOS: APNs already shows the foreground banner & sound.
          // Record the alert id so a subsequent background wake does not duplicate it.
          final alertId = data['alertId']?.toString().trim() ?? '';
          if (alertId.isNotEmpty) {
            await _markAlertIdShown(alertId);
          }
          return WakeOutcome.shown;
        }
        return await _runWake();
      } catch (_) {
        return WakeOutcome.failed;
      }
    });
    _queue = next;
    return next;
  }

  static Future<void> _persistShownAlertId(String alertId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      try {
        await prefs.reload();
      } catch (_) {}
      final existing = (prefs.getStringList(_shownAlertIdsKey) ?? const []).toSet();
      existing.add(alertId);
      final bounded = existing.length <= BackgroundAlertWake.maxRememberedIds
          ? existing
          : existing.skip(existing.length - BackgroundAlertWake.maxRememberedIds).toSet();
      await prefs.setStringList(_shownAlertIdsKey, bounded.toList(growable: false));
    } catch (_) {
      // Best-effort persistence.
    }
  }
}

/// Wires FCM background + foreground alert delivery and native notification tap
/// routing when this build has a working Firebase configuration (#360, #1028).
///
/// Follows the #317 three-shape rule: when Firebase is absent (no
/// `google-services.json` / `GoogleService-Info.plist`, or an unsupported
/// platform), initialization fails and this returns `null` silently without
/// registering any background handler, iOS presentation options, or listeners.
Future<StreamSubscription<T>?> enablePushAlerts<T>({
  @visibleForTesting Future<void> Function()? ensureFirebaseInitialized,
  @visibleForTesting void Function()? registerBackgroundHandler,
  @visibleForTesting Future<void> Function()? configureForegroundPresentation,
  @visibleForTesting Stream<T>? foregroundMessages,
  @visibleForTesting Stream<Map<String, dynamic>>? openedMessageData,
  @visibleForTesting Future<Map<String, dynamic>?> Function()? readInitialMessageData,
  @visibleForTesting bool? isApplePlatform,
  @visibleForTesting bool Function(T message)? hasNotificationPayload,
  @visibleForTesting Map<String, dynamic> Function(T message)? extractData,
  @visibleForTesting Future<void> Function(String alertId)? markAlertIdShown,
  @visibleForTesting NotificationTapController? tapController,
  @visibleForTesting Future<WakeOutcome> Function()? runWake,
}) async {
  try {
    if (ensureFirebaseInitialized != null) {
      await ensureFirebaseInitialized();
    } else if (Firebase.apps.isEmpty) {
      await Firebase.initializeApp();
    }
  } catch (_) {
    // Absent (#317): no Firebase config or unsupported platform. Register nothing.
    return null;
  }

  if (registerBackgroundHandler != null) {
    registerBackgroundHandler();
  } else {
    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
  }

  final apple = isApplePlatform ?? (defaultTargetPlatform == TargetPlatform.iOS);
  var nativePresentationEnabled = false;

  // #1028: On iPhone, enable native foreground presentation options so visible
  // APNs alert payloads render cleanly as a single native banner + sound.
  try {
    if (configureForegroundPresentation != null) {
      await configureForegroundPresentation();
      nativePresentationEnabled = true;
    } else if (apple) {
      await FirebaseMessaging.instance.setForegroundNotificationPresentationOptions(
        alert: true,
        badge: true,
        sound: true,
      );
      nativePresentationEnabled = true;
    }
  } catch (_) {
    // Best-effort on platforms where presentation options are unsupported;
    // fall back to local presentation via onMessage.
    nativePresentationEnabled = false;
  }

  // #1028: Route taps on native APNs/FCM banners into NotificationTapController
  // so tapping a native foreground/background banner opens `/alerts/:id`.
  if (openedMessageData != null) {
    openedMessageData.listen((data) => recordFcmNotificationTap(data, tapController));
  } else {
    FirebaseMessaging.onMessageOpenedApp.listen(
      (msg) => recordFcmNotificationTap(msg.data, tapController),
    );
  }
  unawaited(() async {
    try {
      final initialData = readInitialMessageData != null
          ? await readInitialMessageData()
          : (await FirebaseMessaging.instance.getInitialMessage())?.data;
      if (initialData != null) {
        recordFcmNotificationTap(initialData, tapController);
      }
    } catch (_) {}
  }());

  final bridge = ForegroundPushBridge(
    runWake: runWake ?? () async => (await buildWake()).run(),
    isApplePlatform: apple,
    nativeForegroundPresentationEnabled: nativePresentationEnabled,
    markAlertIdShown: markAlertIdShown,
  );
  final stream = foregroundMessages ?? (FirebaseMessaging.onMessage as Stream<T>);
  return stream.listen((msg) {
    final hasNotif = hasNotificationPayload != null
        ? hasNotificationPayload(msg)
        : (msg is RemoteMessage && msg.notification != null);
    final data = extractData != null
        ? extractData(msg)
        : (msg is RemoteMessage ? msg.data : const <String, dynamic>{});
    unawaited(bridge.handleMessage(hasNotificationPayload: hasNotif, data: data));
  });
}
