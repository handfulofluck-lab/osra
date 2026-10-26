import 'dart:ui' show Locale;

import 'package:flutter_test/flutter_test.dart';
import 'package:familyshield_parent/api/models.dart';
import 'package:familyshield_parent/l10n/l10n.dart';
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
  String category = 'screen_time_exceeded',
}) =>
    Alert.fromJson({
      'id': id,
      'severity': 'warning',
      'category': category,
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

/// The identity mapping, for the rows that are about the wake's flow rather than
/// about what the lock screen says.
VisibleAlert passthrough(Alert a) => VisibleAlert(alertId: a.id, title: a.title, body: a.body);

/// Posts everything except one id, which throws — the shape of a platform
/// channel that refuses mid-loop (#395 review F5).
class ThrowingNotifier implements LocalNotifier {
  ThrowingNotifier({required this.failOn});
  final String failOn;

  @override
  Future<void> show(VisibleAlert alert) async {
    if (alert.alertId == failOn) throw StateError('post failed');
  }
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
      // …and every fresh id is remembered, not only the three shown, so the
      // dropped backlog cannot dribble back out on a later wake (#395 review).
      expect(plan.remember, ['a0', 'a1', 'a2', 'a3', 'a4', 'a5', 'a6', 'a7']);
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
          toVisible: passthrough,
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
        toVisible: passthrough,
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
        toVisible: passthrough,
      ).run();

      expect(stored.length, BackgroundAlertWake.maxRememberedIds);
      expect(stored.contains('fresh'), isTrue);
    });
    test('shows exactly the new alert when a capped backlog is followed by one more', () async {
      // 8 waiting, cap 5: the first wake shows the newest 5 and remembers all 8.
      final first = [for (var i = 0; i < 8; i++) alert('a$i', at: '2026-10-26T0$i:00:00.000Z')];
      await wake(fetch: AlertFetchOk(first)).run();
      expect(notifier.shown.length, 5);

      // A 9th arrives. Only it is new — the three the cap dropped are not.
      final second = [...first, alert('a8', at: '2026-10-26T09:00:00.000Z')];
      notifier.shown.clear();
      expect(await wake(fetch: AlertFetchOk(second)).run(), WakeOutcome.shown);
      expect(notifier.shown.map((v) => v.alertId), ['a8']);
    });

    test('a post that fails stores nothing and is a failure, not a crash, so the next wake shows it again', () async {
      final w = BackgroundAlertWake(
        readJwt: () async => 'session-token',
        fetchAlerts: (_) async => AlertFetchOk([alert('a'), alert('b', at: '2026-10-26T11:00:00.000Z')]),
        notifier: ThrowingNotifier(failOn: 'b'),
        readShown: () async => {...stored},
        writeShown: (ids) async {
          writes++;
          stored = {...ids};
        },
        toVisible: passthrough,
      );

      // #395 review F5: without this, moving writeShown before the posts survives
      // the suite, and a throw escapes the background isolate.
      expect(await w.run(), WakeOutcome.failed);
      expect(writes, 0);
      expect(stored, isEmpty);
    });

    test('a 401 reads the session exactly once, so there is no refresh attempt', () async {
      // #395 review claim 3: "no refresh" must be a test, not a grep. A refresh
      // would have to read the stored refresh token, which means a second read
      // of the session; one read and no write is the observable shape of
      // "terminal".
      var reads = 0;
      final w = BackgroundAlertWake(
        readJwt: () async {
          reads++;
          return 'expired-token';
        },
        fetchAlerts: (_) async => const AlertFetchUnauthorized(),
        notifier: notifier,
        readShown: () async => {},
        writeShown: (_) async => writes++,
        toVisible: passthrough,
      );

      expect(await w.run(), WakeOutcome.unauthorized);
      expect(reads, 1);
      expect(notifier.shown, isEmpty);
      expect(writes, 0);
    });
  });

  group('the lock screen speaks the parent\'s language, and only generic text', () {
    final ar = lookupAppLocalizations(const Locale('ar'));
    final en = lookupAppLocalizations(const Locale('en'));

    test('an Arabic family gets the Arabic category title, not the server English', () {
      final visible = VisibleAlert.from(alert('a', title: 'YouTube video flagged: cats'), l10n: ar, isEnglish: false);

      expect(visible.title, ar.alertTitleDailyLimit);
      expect(visible.title, isNot(contains('YouTube')));
    });

    test('an unknown category under Arabic gives the generic Arabic title, never the server text', () {
      final visible = VisibleAlert.from(
        alert('a', category: 'brand_new_type', title: 'Some new server wording'),
        l10n: ar,
        isEnglish: false,
      );

      expect(visible.title, ar.alertTitleGeneric);
    });

    test('the body is generic and never the alert body', () {
      final visible = VisibleAlert.from(alert('a', body: 'searched: how to hide cuts'), l10n: en, isEnglish: true);

      expect(visible.body, en.alertPushBodyGeneric);
      expect(visible.body, isNot(contains('searched')));
    });

    test('resolveAlertLanguage: stored wins, system follows the device, unknown becomes English', () {
      expect(resolveAlertLanguage('ar', const Locale('en')), 'ar');
      expect(resolveAlertLanguage('en', const Locale('ar')), 'en');
      expect(resolveAlertLanguage('system', const Locale('ar')), 'ar');
      expect(resolveAlertLanguage(null, const Locale('ar')), 'ar');
      expect(resolveAlertLanguage(null, const Locale('fr')), 'en');
      expect(resolveAlertLanguage('klingon', const Locale('en')), 'en');
    });
  });

  group('resolveBackgroundBaseUrl', () {
    test('the URL the parent typed wins, normalized', () {
      expect(resolveBackgroundBaseUrl(' 192.168.1.5:3000/ '), 'http://192.168.1.5:3000');
    });

    test('unusable input with no compile-time default is null, so the wake makes no request', () {
      // kDefaultServerUrl is "" in a test build (it is a compile-time define and
      // the app ships it blank on purpose), so this is the tester-build case the
      // review measured: every wake used to fail on an empty base URL.
      expect(resolveBackgroundBaseUrl(null), isNull);
      expect(resolveBackgroundBaseUrl(''), isNull);
      expect(resolveBackgroundBaseUrl('not a url'), isNull);
    });
  });
}
