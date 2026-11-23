import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import 'background_push.dart';

/// #1028: Serializes foreground FCM wakes through the exact same
/// [BackgroundAlertWake] pipeline (`toVisible` -> `LocalNotifier.show` ->
/// `writeShown`) used by the background handler.
///
/// Serializing in-flight wakes guarantees two back-to-back `onMessage` events
/// cannot race `readShown`/`writeShown` and display the same alert twice.
class ForegroundPushBridge {
  ForegroundPushBridge({
    required Future<WakeOutcome> Function() runWake,
  }) : _runWake = runWake;

  final Future<WakeOutcome> Function() _runWake;
  Future<WakeOutcome> _queue = Future<WakeOutcome>.value(WakeOutcome.nothingNew);

  /// Handles one foreground push event through the shared wake pipeline.
  /// Never throws, matching [BackgroundAlertWake.run].
  Future<WakeOutcome> handleMessage() {
    final next = _queue.then((_) async {
      try {
        return await _runWake();
      } catch (_) {
        return WakeOutcome.failed;
      }
    });
    _queue = next;
    return next;
  }
}

/// Wires FCM background + foreground alert delivery when this build has a
/// working Firebase configuration (#360, #1028).
///
/// Follows the #317 three-shape rule: when Firebase is absent (no
/// `google-services.json` / `GoogleService-Info.plist`, or an unsupported
/// platform), initialization fails and this returns `null` silently without
/// registering any background handler, iOS presentation options, or foreground
/// `onMessage` listener.
Future<StreamSubscription<T>?> enablePushAlerts<T>({
  @visibleForTesting Future<void> Function()? ensureFirebaseInitialized,
  @visibleForTesting void Function()? registerBackgroundHandler,
  @visibleForTesting Future<void> Function()? configureForegroundPresentation,
  @visibleForTesting Stream<T>? foregroundMessages,
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

  // #1028: On iPhone, iOS suppresses banners while the app is in the foreground
  // unless foreground presentation options are enabled explicitly.
  try {
    if (configureForegroundPresentation != null) {
      await configureForegroundPresentation();
    } else {
      await FirebaseMessaging.instance.setForegroundNotificationPresentationOptions(
        alert: true,
        badge: true,
        sound: true,
      );
    }
  } catch (_) {
    // Best-effort on platforms where presentation options are unsupported;
    // keep the onMessage listener active so local notifications still show.
  }

  final bridge = ForegroundPushBridge(
    runWake: runWake ?? () async => (await buildWake()).run(),
  );
  final stream = foregroundMessages ?? (FirebaseMessaging.onMessage as Stream<T>);
  return stream.listen((_) {
    unawaited(bridge.handleMessage());
  });
}
