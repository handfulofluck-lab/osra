import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:familyshield_parent/api/models.dart';
import 'package:familyshield_parent/providers/onboarding_provider.dart';
import 'package:familyshield_parent/push/background_push.dart';
import 'package:familyshield_parent/push/foreground_push.dart';
import 'package:familyshield_parent/push/local_notifier.dart';
import 'package:familyshield_parent/push/notification_tap.dart';

/// #1028: Foreground push handling in the Parent app — shares the exact
/// `toVisible -> LocalNotifier.show -> writeShown` pipeline and cross-handler
/// [AlertPresentationClaimer] with the background handler, selects a single
/// presenter on iOS when the server sends a visible APNs alert, routes native
/// notification taps to `/alerts/:id`, and obeys the #317 three-shape rule.
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

class _FlakyNotifier implements LocalNotifier {
  final List<VisibleAlert> shown = [];
  bool shouldFail = true;

  @override
  Future<void> show(VisibleAlert alert) async {
    if (shouldFail) throw StateError('post failed');
    shown.add(alert);
  }
}

VisibleAlert _toVisible(Alert a) =>
    VisibleAlert(alertId: a.id, title: 'title:${a.category}', body: 'generic:${a.id}');

void main() {
  group('ForegroundPushBridge & cross-handler claim dedupe (#1028)', () {
    test('a foreground message shows once via toVisible -> LocalNotifier.show and persists shown id', () async {
      // Mutant: omitting writeShown or skipping notifier.show in foreground wakes breaks this test.
      final notifier = _RecordingNotifier();
      final shownStore = <String>{};
      final claimer = AlertPresentationClaimer();
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
            claimer: claimer,
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

    test('overlapping background wake and foreground wake held at readShown present once (Finding 1)', () async {
      // Mutant: removing AlertPresentationClaimer.tryClaim lets both handlers read an empty shownStore
      // and both call notifier.show, producing 2 notifications instead of 1.
      final notifier = _RecordingNotifier();
      final shownStore = <String>{};
      final claimer = AlertPresentationClaimer();
      final page = [_alert('alert-overlap-1')];

      var readCount = 0;
      final bothRead = Completer<void>();
      final releaseBoth = Completer<void>();

      BackgroundAlertWake makeWake() => BackgroundAlertWake(
            readJwt: () async => 'jwt-token',
            fetchAlerts: (_) async => AlertFetchOk(page),
            notifier: notifier,
            readShown: () async {
              final snapshot = Set<String>.from(shownStore);
              readCount++;
              if (readCount <= 2) {
                if (readCount == 2 && !bothRead.isCompleted) {
                  bothRead.complete();
                }
                await releaseBoth.future;
              }
              return snapshot;
            },
            writeShown: (ids) async {
              shownStore
                ..clear()
                ..addAll(ids);
            },
            toVisible: _toVisible,
            claimer: claimer,
          );

      final bgFuture = makeWake().run();
      final fgBridge = ForegroundPushBridge(runWake: () => makeWake().run());
      final fgFuture = fgBridge.handleMessage();

      await bothRead.future;
      releaseBoth.complete();

      final outcomes = await Future.wait([bgFuture, fgFuture]);
      expect(outcomes.where((o) => o == WakeOutcome.shown).length, 1);
      expect(outcomes.where((o) => o == WakeOutcome.nothingNew).length, 1);
      expect(notifier.shown.map((v) => v.alertId), ['alert-overlap-1']);
    });

    test('failed presentation releases claim and allows the next wake to retry and show once', () async {
      // Mutant: failing to call claimer.releaseAll on notifier.show error permanently blocks retry.
      final notifier = _FlakyNotifier();
      final shownStore = <String>{};
      final claimer = AlertPresentationClaimer();
      final page = [_alert('alert-retry-1')];

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
            claimer: claimer,
          );

      // First attempt fails -> claim released, nothing written.
      expect(await makeWake().run(), WakeOutcome.failed);
      expect(notifier.shown, isEmpty);
      expect(shownStore, isEmpty);

      // Next attempt succeeds -> shown once and persisted.
      notifier.shouldFail = false;
      final bridge = ForegroundPushBridge(runWake: () => makeWake().run());
      expect(await bridge.handleMessage(), WakeOutcome.shown);
      expect(notifier.shown.map((v) => v.alertId), ['alert-retry-1']);
      expect(shownStore, {'alert-retry-1'});
    });
  });

  group('Single presenter on iOS & native tap routing (Finding 2, #1028)', () {
    test('iOS with native foreground presentation skips local show for visible APNs alert and records id', () async {
      // Mutant: always calling runWake() on iOS even when hasNotificationPayload == true causes
      // double banners and double sound on iPhone.
      var wakeCalls = 0;
      final markedIds = <String>[];
      final bridge = ForegroundPushBridge(
        runWake: () async {
          wakeCalls++;
          return WakeOutcome.shown;
        },
        isApplePlatform: true,
        nativeForegroundPresentationEnabled: true,
        markAlertIdShown: (id) async => markedIds.add(id),
      );

      final outcome = await bridge.handleMessage(
        hasNotificationPayload: true,
        data: const {'alertId': 'alert-ios-1'},
      );

      expect(outcome, WakeOutcome.shown);
      expect(wakeCalls, 0);
      expect(markedIds, ['alert-ios-1']);
    });

    test('iOS grouped native wake avoids a second local presenter', () async {
      var wakeCalls = 0;
      final bridge = ForegroundPushBridge(
        runWake: () async {
          wakeCalls++;
          return WakeOutcome.shown;
        },
        isApplePlatform: true,
        nativeForegroundPresentationEnabled: true,
      );

      final outcome = await bridge.handleMessage(data: const {'w': '1', 'g': '1'});

      expect(outcome, WakeOutcome.shown);
      expect(wakeCalls, 0);
    });

    test('iOS data-only foreground push (no APNs alert) still uses local presenter', () async {
      // Mutant: suppressing all iOS foreground pushes would drop data-only wakes.
      var wakeCalls = 0;
      final bridge = ForegroundPushBridge(
        runWake: () async {
          wakeCalls++;
          return WakeOutcome.shown;
        },
        isApplePlatform: true,
        nativeForegroundPresentationEnabled: true,
      );

      final outcome = await bridge.handleMessage(hasNotificationPayload: false);
      expect(outcome, WakeOutcome.shown);
      expect(wakeCalls, 1);
    });

    test('Android always uses local presenter in foreground even when notification payload is present', () async {
      // Mutant: suppressing local show on Android when notification != null leaves foreground silent on Android.
      var wakeCalls = 0;
      final bridge = ForegroundPushBridge(
        runWake: () async {
          wakeCalls++;
          return WakeOutcome.shown;
        },
        isApplePlatform: false,
        nativeForegroundPresentationEnabled: false,
      );

      final outcome = await bridge.handleMessage(hasNotificationPayload: true);
      expect(outcome, WakeOutcome.shown);
      expect(wakeCalls, 1);
    });

    test('tapping a native APNs/FCM notification routes alertId to NotificationTapController', () async {
      // Mutant: omitting onMessageOpenedApp / getInitialMessage leaves native banner taps unopened.
      final tapController = NotificationTapController();
      final openedController = StreamController<Map<String, dynamic>>();
      final fgController = StreamController<String>();
      addTearDown(() async {
        await openedController.close();
        await fgController.close();
      });

      final sub = await enablePushAlerts<String>(
        ensureFirebaseInitialized: () async {},
        registerBackgroundHandler: () {},
        configureForegroundPresentation: () async {},
        foregroundMessages: fgController.stream,
        openedMessageData: openedController.stream,
        readInitialMessageData: () async => null,
        isApplePlatform: true,
        hasNotificationPayload: (_) => true,
        extractData: (_) => const {'alertId': 'alert-ios-fg'},
        markAlertIdShown: (_) async {},
        tapController: tapController,
        runWake: () async => WakeOutcome.nothingNew,
      );
      addTearDown(() async => sub?.cancel());

      openedController.add(const {'alertId': 'alert-ios-tap-1'});
      await Future<void>.delayed(Duration.zero);
      expect(tapController.consumePendingAlertId(), 'alert-ios-tap-1');
    });

    test('shipping generic wake payload {w: "1"} routes synchronously to /alerts (never null)', () {
      // Mutant: requiring data['alertId'] in recordFcmNotificationTap leaves pendingDestination null
      // for the shipping server wake payload (`services/api/src/lib/push/notify.ts`: { w: "1" }).
      final tapController = NotificationTapController();
      recordFcmNotificationTap(const {'w': '1'}, tapController);
      expect(tapController.pendingDestination, '/alerts');
      expect(
        resolveNotificationAlertRedirect(
          authenticated: true,
          onboardingComplete: true,
          onboardingStep: OnboardingStep.none,
          controller: tapController,
        ),
        '/alerts',
      );
      expect(tapController.pendingDestination, isNull);
    });

    test('warm tap with shipping generic wake {w: "1"} opens /alerts/:id when 1 unacked, /alerts when ambiguous', () async {
      // Mutant: skipping authenticated alerts fetch or failing to fall back to /alerts on 2+ unacked alerts
      // either opens null or guesses the wrong alert card.
      final tapController = NotificationTapController();
      final openedController = StreamController<Map<String, dynamic>>();
      final fgController = StreamController<String>();
      addTearDown(() async {
        await openedController.close();
        await fgController.close();
      });

      var fetched = <Alert>[_alert('only-unacked-1')];
      final sub = await enablePushAlerts<String>(
        ensureFirebaseInitialized: () async {},
        registerBackgroundHandler: () {},
        configureForegroundPresentation: () async {},
        foregroundMessages: fgController.stream,
        openedMessageData: openedController.stream,
        readInitialMessageData: () async => null,
        isApplePlatform: true,
        tapController: tapController,
        fetchAlertsForTap: () async => fetched,
        runWake: () async => WakeOutcome.nothingNew,
      );
      addTearDown(() async => sub?.cancel());

      // Single unambiguous unacknowledged alert -> opens /alerts/:id
      openedController.add(const {'w': '1'});
      await Future<void>.delayed(Duration.zero);
      expect(tapController.consumePendingDestination(), '/alerts/only-unacked-1');

      // Ambiguous (2 unacknowledged alerts) -> opens /alerts so parent picks the right card
      fetched = [_alert('unacked-a'), _alert('unacked-b')];
      openedController.add(const {'w': '1'});
      await Future<void>.delayed(Duration.zero);
      expect(tapController.consumePendingDestination(), '/alerts');
    });

    test('cold tap with shipping generic wake {w: "1"} survives auth gate and opens /alerts after sign-in', () async {
      // Mutant: dropping getInitialMessage generic wake or consuming before auth loses the cold-start tap.
      final tapController = NotificationTapController();
      final fgController = StreamController<String>();
      addTearDown(fgController.close);

      final sub = await enablePushAlerts<String>(
        ensureFirebaseInitialized: () async {},
        registerBackgroundHandler: () {},
        configureForegroundPresentation: () async {},
        foregroundMessages: fgController.stream,
        openedMessageData: const Stream.empty(),
        readInitialMessageData: () async => const {'w': '1'},
        isApplePlatform: true,
        tapController: tapController,
        // Signed out during cold start: authenticated fetch returns null.
        fetchAlertsForTap: () async => null,
        runWake: () async => WakeOutcome.nothingNew,
      );
      addTearDown(() async => sub?.cancel());

      await Future<void>.delayed(Duration.zero);
      // Auth gate holds the destination until authenticated.
      expect(
        resolveNotificationAlertRedirect(
          authenticated: false,
          onboardingComplete: true,
          onboardingStep: OnboardingStep.none,
          controller: tapController,
        ),
        isNull,
      );
      expect(tapController.pendingDestination, '/alerts');

      // Once signed in, GoRouter redirect consumes /alerts.
      expect(
        resolveNotificationAlertRedirect(
          authenticated: true,
          onboardingComplete: true,
          onboardingStep: OnboardingStep.none,
          controller: tapController,
        ),
        '/alerts',
      );
      expect(tapController.pendingDestination, isNull);
    });

    test('cold tap with shipping generic wake {w: "1"} when signed in resolves single unacked alert to /alerts/:id', () async {
      // Mutant: ignoring fetchAlertsForTap on getInitialMessage opens /alerts even when 1 alert is unambiguous.
      final tapController = NotificationTapController();
      final fgController = StreamController<String>();
      addTearDown(fgController.close);

      final sub = await enablePushAlerts<String>(
        ensureFirebaseInitialized: () async {},
        registerBackgroundHandler: () {},
        configureForegroundPresentation: () async {},
        foregroundMessages: fgController.stream,
        openedMessageData: const Stream.empty(),
        readInitialMessageData: () async => const {'w': '1'},
        isApplePlatform: true,
        tapController: tapController,
        fetchAlertsForTap: () async => [_alert('cold-single-1')],
        runWake: () async => WakeOutcome.nothingNew,
      );
      addTearDown(() async => sub?.cancel());

      await Future<void>.delayed(Duration.zero);
      expect(
        resolveNotificationAlertRedirect(
          authenticated: true,
          onboardingComplete: true,
          onboardingStep: OnboardingStep.none,
          controller: tapController,
        ),
        '/alerts/cold-single-1',
      );
    });
  });

  group('enablePushAlerts (#317 three-shape rule)', () {
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
        openedMessageData: const Stream.empty(),
        readInitialMessageData: () async => null,
        runWake: () async => WakeOutcome.shown,
      );

      expect(sub, isNull);
      expect(backgroundRegistered, isFalse);
      expect(presentationConfigured, isFalse);
      expect(controller.hasListener, isFalse);
    });

    test('presentation option error falls back to local presentation and keeps onMessage active', () async {
      // Mutant: letting configureForegroundPresentation throw out of enablePushAlerts drops onMessage.
      final wakeDone = Completer<void>();
      final controller = StreamController<String>();
      addTearDown(controller.close);

      final sub = await enablePushAlerts<String>(
        ensureFirebaseInitialized: () async {},
        registerBackgroundHandler: () {},
        configureForegroundPresentation: () async => throw UnsupportedError('not iOS'),
        foregroundMessages: controller.stream,
        openedMessageData: const Stream.empty(),
        readInitialMessageData: () async => null,
        isApplePlatform: true,
        hasNotificationPayload: (_) => true,
        extractData: (_) => const {'alertId': 'alert-fallback'},
        runWake: () async {
          if (!wakeDone.isCompleted) wakeDone.complete();
          return WakeOutcome.shown;
        },
      );
      addTearDown(() async => sub?.cancel());

      expect(sub, isNotNull);
      expect(controller.hasListener, isTrue);

      controller.add('wake');
      await wakeDone.future;
    });
  });
}
