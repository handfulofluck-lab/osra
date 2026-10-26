import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'push/background_push.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Registered before the first frame so a wake that arrives while the app is
  // starting still has a handler (#360). Not awaited: on a build with no
  // Firebase config this fails by design, and startup must not wait for it.
  unawaited(_enableBackgroundAlerts());
  runApp(const ProviderScope(child: FamilyShieldApp()));
}

/// Wires the FCM background handler when this build can actually use FCM.
///
/// The three-shape rule from #317 and [FcmPushTokenSource]: no
/// `google-services.json` means push is *absent*, not broken. A build made from
/// a clean clone therefore skips this silently instead of crashing at startup,
/// and the same build still runs every other feature.
Future<void> _enableBackgroundAlerts() async {
  try {
    if (Firebase.apps.isEmpty) await Firebase.initializeApp();
    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
  } catch (_) {
    // Absent: no config, or a platform without Firebase. Nothing to register.
  }
}
