import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:familyshield_parent/api/models.dart';
import 'package:familyshield_parent/push/background_push.dart';
import 'package:familyshield_parent/push/foreground_push.dart';
import 'package:familyshield_parent/push/local_notifier.dart';

/// #1028: Foreground push handling in the Parent app — shares the exact
/// `toVisible -> LocalNotifier.show -> writeShown` pipeline with the background
/// handler, sets iOS foreground presentation options, and obeys the #317
/// three-shape rule (no Firebase config -> no listener).
Alert _alert(
  String id, {
  String at = '2026-11-24T09:00:00.000Z',
  String category = 'social_concern',
}) =>
    Alert.fromJson({
      'id': id,
      'severity': 'warning',
      'category': category,
      'title': 'Social concern in WhatsApp',
      'body': 'Flagged message',
      'metadata': const <String, dynamic>{'app': 'whatsapp'},
      'createdAt': at,
      'acknowledged': false,
    });

class _RecordingNotifier implements LocalNotifier {
  final List<VisibleAlert> shown = [];

  @override
  Future<void> show(VisibleAlert alert) async => shown.add(alert);
}

VisibleAlert _toVisible(Alert a) =>
    VisibleAlert(alertId: a.id, title: 'title:${a.category}', body: 'generic:${a.id}');

void main() {
  group('ForegroundPushBridge & shared dedupe (#1028)', () {
    test('a foreground message shows once via toVisible -> LocalNotifier.show and persists shown id', () async {
      // Mutant: omitting writeShown or skipping notifier.show in foreground wakes breaks this test.
      final notifier = _RecordingNotifier();
      final shownStore = <String>{};
      final page = [_alert('alert-fg-1')];

      BackgroundAlertWake makeWake() => BackgroundAlertWake(
            readJwt: () async => 'jwt-token',
            fetchAlerts: (_) async => AlertFetchOk(page),
            notifier: notifier,
            readShown: () async => Set<String>.from(shownStore),
            writeShown: (ids) async {
              shownStore
                ..clear()
                ..addAll(ids);
            },
            toVisible: _toVisible,
          );

      final bridge = ForegroundPushBridge(runWake: () => makeWake().run());

      expect(await bridge.handleMessage(), WakeOutcome.shown);
      expect(notifier.shown.map((v) => v.alertId), ['alert-fg-1']);
      expect(notifier.shown.single.title, 'title:social_concern');
      expect(shownStore, {'alert-fg-1'});

      // Same foreground alert arriving again is deduped.
      expect(await bridge.handleMessage(), WakeOutcome.nothingNew);
      expect(notifier.shown.length, 1);
    });

    test('the same alert id arriving in background and foreground shows once (both orders)', () async {
      // Mutant: using a separate dedupe store for foreground instead of sharing readShown/writeShown
      // would show the same alert twice.
      Future<void> verifyOrder({required bool backgroundFirst}) async {
        final notifier = _RecordingNotifier();
        final shownStore = <String>{};
        final page = [_alert('alert-shared-1')];

        BackgroundAlertWake makeWake() => BackgroundAlertWake(
              readJwt: () async => 'jwt-token',
              fetchAlerts: (_) async => AlertFetchOk(page),
              notifier: notifier,
              readShown: () async => Set<String>.from(shownStore),
              writeShown: (ids) async {
                shownStore
                  ..clear()
                  ..addAll(ids);
              },
              toVisible: _toVisible,
            );

        final bridge = ForegroundPushBridge(runWake: () => makeWake().run());

        if (backgroundFirst) {
          expect(await makeWake().run(), WakeOutcome.shown);
          expect(await bridge.handleMessage(), WakeOutcome.nothingNew);
        } else {
          expect(await bridge.handleMessage(), WakeOutcome.shown);
          expect(await makeWake().run(), WakeOutcome.nothingNew);
        }

        expect(notifier.shown.map((v) => v.alertId), ['alert-shared-1']);
      }

      await verifyOrder(backgroundFirst: true);
      await verifyOrder(backgroundFirst: false);
    });

    test('back-to-back concurrent foreground messages serialize and never show the same alert twice', () async {
      // Mutant: dropping the _queue serialization in ForegroundPushBridge lets both concurrent wakes
      // read an empty shownStore before the first writes, showing alert-race-1 twice.
      final notifier = _RecordingNotifier();
      final shownStore = <String>{};
      final gate = Completer<void>();
      var fetchCalls = 0;

      BackgroundAlertWake makeWake() => BackgroundAlertWake(
            readJwt: () async => 'jwt-token',
            fetchAlerts: (_) async {
              fetchCalls++;
              if (fetchCalls == 1) await gate.future;
              return AlertFetchOk([_alert('alert-race-1')]);
            },
            notifier: notifier,
            readShown: () async => Set<String>.from(shownStore),
            writeShown: (ids) async {
              shownStore
                ..clear()
                ..addAll(ids);
            },
            toVisible: _toVisible,
          );

      final bridge = ForegroundPushBridge(runWake: () => makeWake().run());
      final first = bridge.handleMessage();
      final second = bridge.handleMessage();
      gate.complete();

      final outcomes = await Future.wait([first, second]);
      expect(outcomes, [WakeOutcome.shown, WakeOutcome.nothingNew]);
      expect(notifier.shown.map((v) => v.alertId), ['alert-race-1']);
    });
  });

  group('enablePushAlerts (#317 three-shape rule + iOS presentation + onMessage)', () {
    test('no Firebase config means no listener, no background handler, and no crash (#317)', () async {
      // Mutant: registering onMessage or presentation options outside the Firebase init guard
      // throws or subscribes when Firebase config is absent.
      var backgroundRegistered = false;
      var presentationConfigured = false;
      final controller = StreamController<String>.broadcast();
      addTearDown(controller.close);

      final sub = await enablePushAlerts<String>(
        ensureFirebaseInitialized: () async => throw StateError('No Firebase config'),
        registerBackgroundHandler: () => backgroundRegistered = true,
        configureForegroundPresentation: () async => presentationConfigured = true,
        foregroundMessages: controller.stream,
        runWake: () async => WakeOutcome.shown,
      );

      expect(sub, isNull);
      expect(backgroundRegistered, isFalse);
      expect(presentationConfigured, isFalse);
      expect(controller.hasListener, isFalse);
    });

    test('configured build registers background handler, iOS foreground presentation, and onMessage listener',
        () async {
      // Mutant: omitting configureForegroundPresentation or stream.listen breaks iPhone/foreground alerts.
      var backgroundRegistered = false;
      var presentationConfigured = false;
      final notifier = _RecordingNotifier();
      final shownStore = <String>{};
      final wakeDone = Completer<void>();
      final controller = StreamController<String>();
      addTearDown(controller.close);

      final sub = await enablePushAlerts<String>(
        ensureFirebaseInitialized: () async {},
        registerBackgroundHandler: () => backgroundRegistered = true,
        configureForegroundPresentation: () async => presentationConfigured = true,
        foregroundMessages: controller.stream,
        runWake: () async {
          final outcome = await BackgroundAlertWake(
            readJwt: () async => 'jwt-token',
            fetchAlerts: (_) async => AlertFetchOk([_alert('alert-live-1')]),
            notifier: notifier,
            readShown: () async => Set<String>.from(shownStore),
            writeShown: (ids) async => shownStore.addAll(ids),
            toVisible: _toVisible,
          ).run();
          if (!wakeDone.isCompleted) wakeDone.complete();
          return outcome;
        },
      );
      addTearDown(() async => sub?.cancel());

      expect(sub, isNotNull);
      expect(backgroundRegistered, isTrue);
      expect(presentationConfigured, isTrue);
      expect(controller.hasListener, isTrue);

      controller.add('fcm-foreground-wake');
      await wakeDone.future;

      expect(notifier.shown.map((v) => v.alertId), ['alert-live-1']);
    });

    test('presentation option error does not block onMessage subscription', () async {
      // Mutant: letting configureForegroundPresentation throw out of enablePushAlerts drops onMessage.
      final controller = StreamController<String>();
      addTearDown(controller.close);

      final sub = await enablePushAlerts<String>(
        ensureFirebaseInitialized: () async {},
        registerBackgroundHandler: () {},
        configureForegroundPresentation: () async => throw UnsupportedError('not iOS'),
        foregroundMessages: controller.stream,
        runWake: () async => WakeOutcome.nothingNew,
      );
      addTearDown(() async => sub?.cancel());

      expect(sub, isNotNull);
      expect(controller.hasListener, isTrue);
    });
  });
}
