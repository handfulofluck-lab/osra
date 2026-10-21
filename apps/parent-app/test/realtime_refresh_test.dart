import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:familyshield_parent/api/models.dart';
import 'package:familyshield_parent/providers/auth_provider.dart';
import 'package:familyshield_parent/providers/family_provider.dart';

import 'fake_api_client.dart';

/// Records the effects a realtime message asks for, so the mapping can be
/// asserted without a socket (issue #236).
class RecordingEffects implements RealtimeEffects {
  int alerts = 0;
  int unacknowledged = 0;
  int family = 0;
  final List<String> locations = [];
  final List<LiveActivity> activities = [];

  @override
  void invalidateAlerts() => alerts++;

  @override
  void invalidateUnacknowledgedCount() => unacknowledged++;

  @override
  void invalidateFamily() => family++;

  @override
  void invalidateLocation(String childId) => locations.add(childId);

  @override
  void updateLiveActivity(LiveActivity activity) => activities.add(activity);
}

/// A provider whose only job is to hand a test the same [RealtimeEffects]
/// adapter `wsProvider` builds from its `Ref`.
final _effectsProvider = Provider<RealtimeEffects>((ref) => RealtimeEffects.fromRef(ref));

void main() {
  group('applyRealtimeMessage', () {
    test('an alert invalidates the feed, the badge and the family overview', () {
      final effects = RecordingEffects();
      applyRealtimeMessage(effects, {
        'type': 'alert',
        'payload': {'id': 'a1', 'attemptCount': 3, 'acknowledged': false},
      });

      expect(effects.alerts, 1);
      expect(effects.unacknowledged, 1);
      expect(effects.family, 1);
      expect(effects.locations, isEmpty);
      expect(effects.activities, isEmpty);
    });

    test('a location invalidates that child and the family overview', () {
      final effects = RecordingEffects();
      applyRealtimeMessage(effects, {
        'type': 'location',
        'payload': {'childId': 'child-1', 'lat': 1.0, 'lng': 2.0},
      });

      expect(effects.locations, ['child-1']);
      expect(effects.family, 1);
      expect(effects.alerts, 0);
      expect(effects.unacknowledged, 0);
      expect(effects.activities, isEmpty);
    });

    test('a location without childId only refreshes the family overview', () {
      final effects = RecordingEffects();
      applyRealtimeMessage(effects, {
        'type': 'location',
        'payload': {'lat': 1.0, 'lng': 2.0},
      });

      expect(effects.locations, isEmpty);
      expect(effects.family, 1);
      expect(effects.alerts, 0);
      expect(effects.unacknowledged, 0);
    });

    test('a live_activity updates the overlay for that child', () {
      final effects = RecordingEffects();
      applyRealtimeMessage(effects, {
        'type': 'live_activity',
        'payload': {'childId': 'child-1', 'app': 'com.example.game', 'minutesToday': 12},
      });

      expect(effects.activities, hasLength(1));
      expect(effects.activities.single.childId, 'child-1');
      expect(effects.activities.single.app, 'com.example.game');
      expect(effects.activities.single.minutesToday, 12);
      expect(effects.alerts, 0);
      expect(effects.unacknowledged, 0);
      expect(effects.family, 0);
    });

    test('an unknown type does nothing', () {
      final effects = RecordingEffects();
      applyRealtimeMessage(effects, {'type': 'device_paired', 'payload': {'id': 'dev-1'}});

      expect(effects.alerts, 0);
      expect(effects.unacknowledged, 0);
      expect(effects.family, 0);
      expect(effects.locations, isEmpty);
      expect(effects.activities, isEmpty);
    });
  });

  group('the queue reacts to an aggregate update', () {
    late FakeApiClient api;
    late ProviderContainer container;
    late int unacked;
    late List<Map<String, dynamic>> feed;

    setUp(() {
      unacked = 0;
      feed = [];
      api = FakeApiClient({
        ...standardRoutes(),
        'GET /v1/alerts': (req) => req.query['ack'] == 'false'
            ? {
                'items': <dynamic>[],
                'meta': {'total': unacked, 'page': 1, 'limit': 1},
              }
            : {'items': feed, 'total': feed.length, 'page': 1, 'limit': 20},
      });
      container = ProviderContainer(overrides: [apiClientProvider.overrideWithValue(api)]);
    });

    tearDown(() => container.dispose());

    test('an alert message moves the badge 0 -> 1 and refreshes the list', () async {
      expect(await container.read(unacknowledgedCountProvider.future), 0);
      expect((await container.read(alertsProvider(const AlertFilter()).future)).items, isEmpty);
      expect(api.calls('GET', '/v1/alerts'), hasLength(2));

      // The server's aggregate update: the row is unread again at a higher count.
      feed = [
        {
          ...alertJson('a1', 'critical', 'sos', 'SOS pressed', DateTime.now()),
          'body': 'SOS pressed — 3 attempts',
          'attemptCount': 3,
        },
      ];
      unacked = 1;

      applyRealtimeMessage(container.read(_effectsProvider), {
        'type': 'alert',
        'payload': {'id': 'a1', 'attemptCount': 3, 'acknowledged': false},
      });

      expect(await container.read(unacknowledgedCountProvider.future), 1);
      final page = await container.read(alertsProvider(const AlertFilter()).future);
      expect(page.items, hasLength(1));
      expect(page.items.single.body, 'SOS pressed — 3 attempts');

      expect(api.calls('GET', '/v1/alerts').where((r) => r.query['ack'] == 'false'), hasLength(2));
      expect(api.calls('GET', '/v1/alerts').where((r) => r.query['ack'] == null), hasLength(2));
    });

    test('a location message does not refetch the badge', () async {
      expect(await container.read(unacknowledgedCountProvider.future), 0);

      applyRealtimeMessage(container.read(_effectsProvider), {
        'type': 'location',
        'payload': {'childId': 'child-1'},
      });

      // The badge was invalidated by nothing, so reading it again is served
      // from the cache: one request, and the value is unchanged.
      expect(await container.read(unacknowledgedCountProvider.future), 0);
      expect(api.calls('GET', '/v1/alerts').where((r) => r.query['ack'] == 'false'), hasLength(1));
    });
  });
}
