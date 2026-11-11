import 'package:familyshield_parent/api/models.dart';
import 'package:flutter_test/flutter_test.dart';

/// ADR-0034 decision 3 — the "Phone setup" block of `GET /v1/devices`, parsed on the parent side.
///
/// The states are the phone's own verdict, except `not_supported`, which is the **server's** word from its
/// static table. The one distinction this suite exists to pin: an **absent** feature key is "the phone did not
/// say", never `unavailable` — a build that cannot do a feature omits it rather than claiming it.
void main() {
  Map<String, dynamic> deviceJson({Map<String, dynamic>? setup}) => {
        'id': 'dev-1',
        'childId': 'child-1',
        'platform': 'android',
        'model': 'Pixel 7a',
        'osVersion': '15',
        'status': 'online',
        'batteryPct': 80,
        if (setup != null) 'setup': setup,
      };

  test('a device that never reported carries no setup, which is "not known yet"', () {
    final device = Device.fromJson(deviceJson());
    expect(device.setup, isNull);
  });

  test('the whole block parses: features, missing, stale, age and other spaces', () {
    final device = Device.fromJson(deviceJson(setup: {
      'reportedAt': '2026-11-10T09:15:00.000Z',
      'stale': true,
      'features': {'lock_screen': 'ready', 'web_filter': 'unavailable', 'notification_scan': 'not_supported'},
      'missing': ['accessibility', 'location'],
      'profiles': {
        'others': 1,
        'kinds': ['clone'],
      },
    }));
    final setup = device.setup!;
    expect(setup.reportedAt, DateTime.utc(2026, 11, 10, 9, 15));
    expect(setup.stale, isTrue);
    expect(setup.feature('lock_screen'), 'ready');
    expect(setup.feature('web_filter'), 'unavailable');
    expect(setup.feature('notification_scan'), 'not_supported');
    expect(setup.missing, ['accessibility', 'location']);
    expect(setup.profiles!.others, 1);
    expect(setup.profiles!.kinds, ['clone']);
  });

  test('an absent feature key is "not said", not "unavailable"', () {
    // The Play artefact omits notification_scan and call_sms_log rather than claiming not_supported, so an
    // absent key must not be rendered as a fault.
    final setup = DeviceSetup.fromJson({
      'features': {'lock_screen': 'ready'},
      'missing': <String>[],
    });
    expect(setup.feature('lock_screen'), 'ready');
    expect(setup.feature('call_sms_log'), isNull);
    expect(setup.feature('notification_scan'), isNull);
  });

  test('a device with no other spaces reports zero, and no profiles at all stays null', () {
    expect(DeviceSetup.fromJson({'features': {}, 'profiles': null}).profiles, isNull);
    final withZero = DeviceSetup.fromJson({
      'profiles': {'others': 0, 'kinds': <String>[]},
    });
    expect(withZero.profiles!.others, 0);
    expect(withZero.profiles!.kinds, isEmpty);
  });

  test('a malformed block degrades to empty rather than throwing', () {
    // The field arrives from the server, but a parse failure must not take the whole device list with it.
    final setup = DeviceSetup.fromJson({
      'features': 'not a map',
      'missing': 'not a list',
      'profiles': 42,
    });
    expect(setup.features, isEmpty);
    expect(setup.missing, isEmpty);
    expect(setup.profiles, isNull);
    expect(setup.stale, isFalse);
  });

  test('an unknown feature key is kept, so a newer phone is not silently blanked', () {
    final setup = DeviceSetup.fromJson({
      'features': {'some_future_feature': 'ready'},
    });
    expect(setup.feature('some_future_feature'), 'ready');
  });
}
