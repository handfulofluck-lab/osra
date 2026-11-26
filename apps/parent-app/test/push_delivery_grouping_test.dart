import 'package:familyshield_parent/api/models.dart';
import 'package:familyshield_parent/l10n/l10n.dart';
import 'package:familyshield_parent/push/background_push.dart';
import 'package:familyshield_parent/push/local_notifier.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';

final _english = lookupAppLocalizations(const Locale('en'));

const _groupedAlert = 'fixture-contact-one';
const _secondContact = 'fixture-contact-two';
const _child = 'fixture-child';

String _time(int minute) =>
    DateTime.utc(2026, 11, 26, 8, minute).toIso8601String();

Map<String, Object> _delivery(String id, int sequence, int minute) => {
      'id': id,
      'seq': sequence,
      'createdAt': _time(minute),
    };

Alert _alert(
  String alertId, {
  Map<String, Object> metadata = const {},
  int createdMinute = 0,
  int updatedMinute = 0,
  int attemptCount = 1,
  String severity = 'warning',
  bool acknowledged = false,
}) =>
    Alert.fromJson({
      'id': alertId,
      'childId': _child,
      'category': 'social_concern',
      'severity': severity,
      'title': 'Synthetic private alert title',
      'body': 'Synthetic private message body',
      'metadata': metadata,
      'createdAt': _time(createdMinute),
      'updatedAt': _time(updatedMinute),
      'attemptCount': attemptCount,
      'acknowledged': acknowledged,
    });

Alert _groupedDelivery(
  int sequence, {
  required int minute,
  required int attemptCount,
}) =>
    _alert(
      _groupedAlert,
      metadata: {
        'pushDeliveryId': 'fixture-delivery-$sequence',
        'pushDeliverySeq': sequence,
      },
      updatedMinute: minute,
      attemptCount: attemptCount,
    );

class _WakeHarness {
  final notifier = FlutterLocalNotifier();
  final claimer = AlertPresentationClaimer();
  Set<String> _shown = {};

  // Each call constructs the same pipeline used by background/foreground
  // workers. The stored notification IDs outlive individual wakes.
  Future<WakeOutcome> run(
    List<Alert> alerts, {
    bool presentGroupedDeliveries = true,
  }) =>
      BackgroundAlertWake(
        presentGroupedDeliveries: presentGroupedDeliveries,
        readJwt: () async => 'synthetic-session',
        fetchAlerts: (_) async => AlertFetchOk(alerts),
        notifier: notifier,
        readShown: () async => {..._shown},
        writeShown: (ids) async => _shown = {...ids},
        toVisible: (alert) =>
            VisibleAlert.from(alert, l10n: _english, isEnglish: true),
        claimer: claimer,
      ).run();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  AndroidFlutterLocalNotificationsPlugin.registerWith();
  const channel = MethodChannel('dexterous.com/flutter/local_notifications');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late _WakeHarness wake;
  late List<Map<Object?, Object?>> posts;

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    wake = _WakeHarness();
    posts = [];
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'initialize') return true;
      if (call.method == 'show') {
        posts.add(Map<Object?, Object?>.from(call.arguments as Map));
      }
      return null;
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  test(
      '#1139: five events for one card show three notifications and one summary',
      () async {
    for (var event = 1; event <= 3; event++) {
      expect(
          await wake.run(
              [_groupedDelivery(event, minute: event, attemptCount: event)]),
          WakeOutcome.shown);
      expect(posts, hasLength(event));
    }

    // The fourth and fifth events change the card but do not fire a delivery.
    for (var event = 4; event <= 5; event++) {
      expect(
          await wake
              .run([_groupedDelivery(3, minute: event, attemptCount: event)]),
          WakeOutcome.nothingNew);
      expect(posts, hasLength(3));
    }

    final summary = _groupedDelivery(4, minute: 10, attemptCount: 5);
    expect(await wake.run([summary]), WakeOutcome.shown);
    expect(await wake.run([summary]), WakeOutcome.nothingNew);

    expect(posts, hasLength(4));
    expect(posts.map((post) => post['id']).toSet(), hasLength(4));
    expect(posts.map((post) => post['payload']), List.filled(4, _groupedAlert));
    expect(posts.map((post) => post['body']),
        everyElement(_english.alertPushBodyGeneric));
  });

  test(
      '#1139: a critical fourth event appears immediately on its own contact card',
      () async {
    for (var event = 1; event <= 3; event++) {
      expect(
          await wake.run(
              [_groupedDelivery(event, minute: event, attemptCount: event)]),
          WakeOutcome.shown);
    }

    final critical = _alert(
      _secondContact,
      metadata: {'pushDeliveryId': 'fixture-critical', 'pushDeliverySeq': 1},
      createdMinute: 4,
      updatedMinute: 4,
      severity: 'critical',
    );
    final older = _groupedDelivery(3, minute: 3, attemptCount: 3);
    expect(await wake.run([critical, older]), WakeOutcome.shown);
    expect(posts, hasLength(4));
    expect(posts.map((post) => post['id']).toSet(), hasLength(4));
    expect(posts.last['payload'], _secondContact);
    expect(await wake.run([critical, older]), WakeOutcome.nothingNew);
  });

  test(
      '#1139: one coalesced wake replays each fired delivery once, in delivery order',
      () async {
    final grouped = _alert(
      _groupedAlert,
      metadata: {
        'pushDeliveryId': 'fixture-summary',
        'pushDeliverySeq': 4,
        'pushDeliveries': [
          _delivery('fixture-summary', 4, 10),
          _delivery('fixture-second', 2, 2),
          _delivery('fixture-first', 1, 1),
          _delivery('fixture-third', 3, 4),
        ],
      },
      updatedMinute: 12,
      attemptCount: 5,
    );
    final separate = _alert('fixture-legacy-midway', createdMinute: 3);
    final page = [grouped, separate];

    expect(await wake.run(page), WakeOutcome.shown);
    expect(posts.map((post) => post['payload']), [
      _groupedAlert,
      _groupedAlert,
      separate.id,
      _groupedAlert,
      _groupedAlert,
    ]);
    expect(posts.map((post) => post['id']).toSet(), hasLength(5));
    expect(await wake.run(page), WakeOutcome.nothingNew);
    expect(posts, hasLength(5));
  });

  test(
      '#1139: a history larger than the seen-ID cap stays quiet after one wake',
      () async {
    Alert historyFor(int contact, {bool addDelivery = false}) {
      final alertId = 'fixture-burst-contact-$contact';
      final history = [
        for (var sequence = 1; sequence <= 4; sequence++)
          _delivery(
              '$alertId-delivery-$sequence', sequence, contact * 4 + sequence),
        if (addDelivery) _delivery('$alertId-delivery-5', 5, 70),
      ];
      return _alert(
        alertId,
        metadata: {
          'pushDeliveryId': history.last['id']!,
          'pushDeliverySeq': history.last['seq']!,
          'pushDeliveries': history,
        },
        createdMinute: contact * 4,
      );
    }

    // One authenticated page contains 60 deliveries across 15 alert cards.
    // Only the newest five are shown. The other 55 must not return on the next wake.
    final page = [
      for (var contact = 0; contact < 15; contact++) historyFor(contact)
    ];
    expect(await wake.run(page), WakeOutcome.shown);
    expect(posts.map((post) => post['payload']), [
      page[13].id,
      ...List.filled(4, page[14].id),
    ]);
    expect(posts.map((post) => post['id']).toSet(), hasLength(5));

    expect(await wake.run(page), WakeOutcome.nothingNew);
    expect(posts, hasLength(5));

    // A later delivery for the oldest card still posts once.
    final later = [historyFor(0, addDelivery: true), ...page.skip(1)];
    expect(await wake.run(later), WakeOutcome.shown);
    expect(posts, hasLength(6));
    expect(posts.last['payload'], page.first.id);
    expect(await wake.run(later), WakeOutcome.nothingNew);
    expect(posts, hasLength(6));
  });

  test('#1139: a later sequence does not silence an earlier unseen delivery',
      () async {
    final newer = _groupedDelivery(2, minute: 2, attemptCount: 2);
    expect(await wake.run([newer]), WakeOutcome.shown);
    expect(posts, hasLength(1));

    // A later page includes the missing older delivery and the one already seen.
    final recovered = _alert(
      _groupedAlert,
      metadata: {
        'pushDeliveryId': 'fixture-delivery-2',
        'pushDeliverySeq': 2,
        'pushDeliveries': [
          _delivery('fixture-delivery-1', 1, 1),
          _delivery('fixture-delivery-2', 2, 2),
        ],
      },
      updatedMinute: 2,
      attemptCount: 2,
    );
    expect(await wake.run([recovered]), WakeOutcome.shown);
    expect(posts, hasLength(2));
    expect(posts.map((post) => post['id']).toSet(), hasLength(2));
    expect(posts.map((post) => post['payload']), List.filled(2, _groupedAlert));
    expect(await wake.run([recovered]), WakeOutcome.nothingNew);
    expect(posts, hasLength(2));
  });

  test('#1139: an unrelated wake keeps a new silent-only contact card quiet',
      () async {
    final silent = _alert(
      _secondContact,
      metadata: {'pushDeliverySeq': 0},
      createdMinute: 1,
    );
    expect(await wake.run([silent]), WakeOutcome.nothingNew);
    expect(posts, isEmpty);

    final legacy = _alert(_groupedAlert);
    expect(await wake.run([silent, legacy]), WakeOutcome.shown);
    expect(posts.map((post) => post['payload']), [_groupedAlert]);

    final legacyChanged =
        _alert(_groupedAlert, updatedMinute: 2, attemptCount: 2);
    expect(await wake.run([silent, legacyChanged]), WakeOutcome.nothingNew);
    expect(posts, hasLength(1));
  });

  test('#1139: acknowledged alerts do not replay stored deliveries', () async {
    final acknowledged = _alert(
      _groupedAlert,
      metadata: {
        'pushDeliveryId': 'fixture-first',
        'pushDeliverySeq': 1,
        'pushDeliveries': [_delivery('fixture-first', 1, 1)],
      },
      acknowledged: true,
    );

    expect(await wake.run([acknowledged]), WakeOutcome.nothingNew);
    expect(posts, isEmpty);
  });

  test('a native presenter leaves managed deliveries out of the local queue',
      () async {
    final grouped = _groupedDelivery(1, minute: 1, attemptCount: 1);
    final legacy = _alert('fixture-legacy', createdMinute: 2);
    final page = [grouped, legacy];

    expect(await wake.run(page, presentGroupedDeliveries: false),
        WakeOutcome.shown);
    expect(posts.map((post) => post['payload']), [legacy.id]);

    expect(await wake.run(page), WakeOutcome.shown);
    expect(posts.map((post) => post['payload']), [legacy.id, grouped.id]);
    expect(await wake.run(page), WakeOutcome.nothingNew);
  });
}
