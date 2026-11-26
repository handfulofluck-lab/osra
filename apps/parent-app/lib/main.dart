import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'core/date_formatting.dart';
import 'push/foreground_push.dart';
import 'push/local_notifier.dart';

Future<void> main() async {
  await configureDateFormatting();
  WidgetsFlutterBinding.ensureInitialized();
  // Registered before the first frame so a wake that arrives while the app is
  // starting or open in the foreground still has a handler (#360, #1028). Not
  // awaited: on a build with no Firebase config this skips silently by design
  // (#317), and startup must not wait for it.
  unawaited(enablePushAlerts());
  // #972: capture cold-start and warm notification taps so GoRouter opens `/alerts/:id`
  // after authentication finishes.
  unawaited(FlutterLocalNotifier.registerTapHandlers());
  runApp(const ProviderScope(child: FamilyShieldApp()));
}
