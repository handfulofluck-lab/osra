import 'package:flutter_test/flutter_test.dart';
import 'package:familyshield_parent/api/models.dart';
import 'package:familyshield_parent/push/alert_notification.dart';
import 'package:familyshield_parent/push/background_push.dart';
import 'package:familyshield_parent/push/local_notifier.dart';

/// #360: a wake must show the parent what is new, once, and nothing at all when
/// there is no session. These rows hold that without a phone, a plugin or a
/// network — the handler's decisions are pure, and [BackgroundAlertWake] takes
/// every side effect as a seam.

Alert alert(
  String id, {
  bool acknowledged = false,
  String? at = '2026-10-26T10:00:00.000Z',
  String title = 'Screen time',
  String body = 'Time is up for Alex',
}) =>
    Alert.fromJson({
      'id': id,
      'severity': 'warning',
      'category': 'screen_time_exceeded',
      'title': title,
      'body': body,
      'metadata': const <String, dynamic>{},
      'createdAt': at,
      'acknowledged': acknowledged,
    });

class RecordingNotifier implements LocalNotifier {
  final List<VisibleAlert> shown = [];

  @override
  Future<void> show(VisibleAlert alert) async => shown.add(alert);
}

void main() {
  group('planNotifications', () {
    test('shows unacknowledged alerts oldest first, so the newest wins the shade', () {
      final plan = planNotifications(
        alerts: [
          alert('c', at: '2026-10-26T12:00:00.000Z'),
          alert('a', at: '2026-10-26T10:00:00.000Z'),
          alert('b', at: '2026-10-26T11:00:00.000Z'),
        ],
        alreadyShown: const {},
      );

      expect(plan.toShow.map((a) => a.id), ['a', 'b', 'c']);
      expect(plan.remember, ['a', 'b', 'c']);
    });

    test('never shows an alert the parent already acknowledged in the app', () {
      final plan = planNotifications(
        alerts: [alert('seen', acknowledged: true), alert('new')],
        alreadyShown: const {},
      );

      expect(plan.toShow.map((a) => a.id), ['new']);
    });

    test('never shows the same alert twice across wakes', () {
      final plan = planNotifications(alerts: [alert('a'), alert('b')], alreadyShown: const {'a'});

      expect(plan.toShow.map((a) => a.id), ['b']);
      expect(plan.remember, ['b']);
    });

    test('drops a duplicate id inside one page', () {
      final plan = planNotifications(alerts: [alert('a'), alert('a')], alreadyShown: const {});

      expect(plan.toShow.map((a) => a.id), ['a']);
    });

    test('keeps the newest when the backlog is larger than the cap', () {
      final plan = planNotifications(
        alerts: [
          for (var i = 0; i < 8; i++) alert('a$i', at: '2026-10-26T0$i:00:00.000Z'),
        ],
        alreadyShown: const {},
        max: 3,
      );

      expect(plan.toShow.map((a) => a.id), ['a5', 'a6', 'a7']);
    });

    test('treats an unparseable date as the oldest rather than the newest', () {
      final plan = planNotifications(
        alerts: [alert('no-date', at: null), alert('dated', at: '2026-10-26T10:00:00.000Z')],
        alreadyShown: const {},
      );

      expect(plan.toShow.map((a) => a.id), ['no-date', 'dated']);
    });

    test('is empty when there is nothing new, and remembers nothing', () {
      final plan = planNotifications(alerts: [alert('a', acknowledged: true)], alreadyShown: const {'b'});

      expect(plan.isEmpty, isTrue);
      expect(plan.remember, isEmpty);
    });
  });

  group('BackgroundAlertWake', () {
    late RecordingNotifier notifier;
    late Set<String> stored;
    late int writes;

    setUp(() {
      notifier = RecordingNotifier();
      stored = {};
      writes = 0;
    });

    BackgroundAlertWake wake({
      String? jwt = 'session-token',
      Object? fetch,
      Future<Object> Function(String)? fetchAlerts,
    }) =>
        BackgroundAlertWake(
          readJwt: () async => jwt,
          fetchAlerts: fetchAlerts ?? (_) async => fetch ?? AlertFetchOk([alert('a')]),
          notifier: notifier,
          readShown: () async => {...stored},
          writeShown: (ids) async {
            writes++;
            stored = {...ids};
          },
        );

    test('shows nothing and fetches nothing when the parent is signed out', () async {
      var fetched = false;
      final w = BackgroundAlertWake(
        readJwt: () async => null,
        fetchAlerts: (_) async {
          fetched = true;
          return AlertFetchOk([alert('a')]);
        },
        notifier: notifier,
        readShown: () async => {},
        writeShown: (_) async => writes++,
      );

      expect(await w.run(), WakeOutcome.signedOut);
      expect(fetched, isFalse);
      expect(notifier.shown, isEmpty);
      expect(writes, 0);
    });

    test('a 401 ends the wake without showing or refreshing anything', () async {
      final outcome = await wake(fetch: const AlertFetchUnauthorized()).run();

      expect(outcome, WakeOutcome.unauthorized);
      expect(notifier.shown, isEmpty);
      expect(writes, 0);
    });

    test('a failed fetch shows nothing and stores nothing, so the next wake retries', () async {
      final outcome = await wake(fetch: const AlertFetchFailed('connectionError')).run();

      expect(outcome, WakeOutcome.failed);
      expect(notifier.shown, isEmpty);
      expect(writes, 0);
    });

    test('a thrown fetch is a failure, not a crash', () async {
      final outcome = await wake(fetchAlerts: (_) async => throw StateError('boom')).run();

      expect(outcome, WakeOutcome.failed);
      expect(notifier.shown, isEmpty);
    });

    test('shows the new alerts and remembers their ids', () async {
      final outcome = await wake(fetch: AlertFetchOk([alert('a'), alert('b', at: '2026-10-26T11:00:00.000Z')])).run();

      expect(outcome, WakeOutcome.shown);
      expect(notifier.shown.map((v) => v.alertId), ['a', 'b']);
      expect(stored, {'a', 'b'});
      expect(writes, 1);
    });

    test('a second wake over the same page shows nothing and writes nothing', () async {
      final page = AlertFetchOk([alert('a')]);
      await wake(fetch: page).run();
      final before = writes;

      expect(await wake(fetch: page).run(), WakeOutcome.nothingNew);
      expect(notifier.shown.map((v) => v.alertId), ['a']);
      expect(writes, before);
    });

    test('the shown store is bounded, so months of wakes cannot grow it forever', () async {
      final many = {for (var i = 0; i < BackgroundAlertWake.maxRememberedIds + 10; i++) 'old-$i'};

      await BackgroundAlertWake(
        readJwt: () async => 't',
        fetchAlerts: (_) async => AlertFetchOk([alert('fresh')]),
        notifier: notifier,
        readShown: () async => many,
        writeShown: (ids) async => stored = {...ids},
      ).run();

      expect(stored.length, BackgroundAlertWake.maxRememberedIds);
      expect(stored.contains('fresh'), isTrue);
    });
  });

  group('VisibleAlert', () {
    test('carries the server text, because the background isolate has no locale context', () {
      final visible = VisibleAlert.from(alert('a', title: 'وقت الشاشة', body: 'انتهى وقت أليكس'));

      expect(visible.alertId, 'a');
      expect(visible.title, 'وقت الشاشة');
      expect(visible.body, 'انتهى وقت أليكس');
    });

    test('falls back to the app name when an alert has no title', () {
      expect(VisibleAlert.from(alert('a', title: '')).title, 'OSRA');
    });
  });
}
