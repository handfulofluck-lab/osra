import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:familyshield_parent/api/models.dart';

/// Issue #601. Two rules, both about reading the API's answer instead of inventing one:
///
/// * the online/offline word is the server's `status`; `lastSeen` is an age shown beside it, not a
///   verdict computed again on the parent's clock. The old rule was a 15-minute window
///   (`kDeviceOnlineWindow`/`isDeviceOnline`, deleted with this file), which called a healthy
///   suspended iPhone offline while `GET /v1/devices` answered `online`;
/// * the "Phone setup" block keys off `setup.reportedAt`, because a current server always sends the
///   `setup` object and uses `reportedAt: null` inside it for "never reported".
Device _device({
  String status = 'online',
  Duration lastSeenAgo = const Duration(hours: 4),
  Map<String, dynamic>? setup,
}) =>
    Device.fromJson({
      'id': 'dev-1',
      'childId': 'child-1',
      'platform': 'ios',
      'model': 'iPhone 15',
      'osVersion': '18.1',
      'status': status,
      'batteryPct': 64,
      'lastSeen': DateTime.now().toUtc().subtract(lastSeenAgo).toIso8601String(),
      if (setup != null) 'setup': setup,
    });

void main() {
  group('the online word is the API\'s status (#601)', () {
    /// Mutant: derive the word from `lastSeen` again (the deleted `isDeviceOnline`) and this goes red.
    test('a device the server calls online is online however old its lastSeen is', () {
      expect(_device(status: 'online', lastSeenAgo: const Duration(hours: 4)).isOnline, isTrue);
      expect(_device(status: 'online', lastSeenAgo: const Duration(minutes: 1)).isOnline, isTrue);
    });

    test('a device the server calls offline is offline, however recent its lastSeen is', () {
      expect(_device(status: 'offline', lastSeenAgo: const Duration(minutes: 1)).isOnline, isFalse);
    });

    test('a device with no lastSeen yet is whatever the server says', () {
      final never = Device.fromJson({
        'id': 'dev-1',
        'childId': 'child-1',
        'platform': 'ios',
        'model': 'iPhone 15',
        'osVersion': '18.1',
        'status': 'online',
        'batteryPct': 64,
      });
      expect(never.lastSeen, isNull);
      expect(never.isOnline, isTrue);
    });

    /// Mutant: one screen re-derives the word from a local window and the dashboard and the child page
    /// disagree about the same phone again — the defect this issue is about.
    test('neither screen keeps a clock rule of its own', () {
      for (final path in [
        'lib/features/dashboard/dashboard_screen.dart',
        'lib/features/children/child_detail_screen.dart',
      ]) {
        final source = File(path).readAsStringSync();
        expect(source, contains('isOnline'), reason: path);
        expect(source, isNot(contains('isDeviceOnline')), reason: path);
        expect(source, isNot(contains('kDeviceOnlineWindow')), reason: path);
      }
    });
  });

  group('a capability report is recognised by its reportedAt (#601)', () {
    test('a setup with a reportedAt carries the report', () {
      final d = _device(setup: {
        'reportedAt': '2026-11-12T08:00:00.000Z',
        'stale': false,
        'features': {'lock_screen': 'ready'},
        'missing': <String>[],
      });
      expect(d.hasCapabilityReport, isTrue);
      expect(d.setup!.features['lock_screen'], 'ready');
    });

    /// The server's "no report" shape (`services/api/src/lib/capabilities.ts` `setupFor`): the object is
    /// there, the receipt time is not. Reading the object alone would call this a report.
    ///
    /// Mutant: test `device.setup == null` instead and this goes red.
    test('a setup whose reportedAt is null is not a report', () {
      final d = _device(setup: {
        'reportedAt': null,
        'stale': true,
        'features': <String, String>{},
        'missing': <String>[],
      });
      expect(d.setup, isNotNull);
      expect(d.hasCapabilityReport, isFalse);
    });

    test('a device from an older server, with no setup key at all, has no report', () {
      expect(_device().setup, isNull);
      expect(_device().hasCapabilityReport, isFalse);
    });
  });
}
