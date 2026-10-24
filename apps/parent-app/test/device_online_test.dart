import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:familyshield_parent/features/dashboard/dashboard_screen.dart' show isDeviceOnline, kDeviceOnlineWindow;

/// Roadmap 5.8 (#353): an idle phone that the server can wake by push now polls every 10 minutes, so
/// the "online" dot must stay green across one poll interval. The old 3-minute window turned a
/// healthy idle phone grey most of the time (it already flickered at the old 5-minute location ping).
void main() {
  final now = DateTime.utc(2026, 10, 24, 1, 0);

  test('the window is 15 minutes', () {
    expect(kDeviceOnlineWindow, const Duration(minutes: 15));
  });

  /// Mutant: put the 3-minute window back and this fails at 10 minutes.
  test('a phone one push-poll interval (10 minutes) behind is online', () {
    expect(isDeviceOnline(now.subtract(const Duration(minutes: 10)), now: now), isTrue);
  });

  test('just inside the window is online, the window itself is offline', () {
    expect(isDeviceOnline(now.subtract(const Duration(minutes: 15)).add(const Duration(seconds: 1)), now: now), isTrue);
    expect(isDeviceOnline(now.subtract(const Duration(minutes: 15)), now: now), isFalse);
    expect(isDeviceOnline(now.subtract(const Duration(hours: 2)), now: now), isFalse);
  });

  test('a device that never checked in is offline', () {
    expect(isDeviceOnline(null, now: now), isFalse);
  });

  /// lastSeen is the server's clock; a parent phone whose clock runs behind sees a fresh one in the future.
  test('a lastSeen slightly in the future counts as online', () {
    expect(isDeviceOnline(now.add(const Duration(seconds: 30)), now: now), isTrue);
  });

  /// Mutant: one screen keeps its own `Duration(minutes: 3)` and the dashboard and the child page
  /// disagree about the same phone. Both must go through the one rule.
  test('the dashboard and the child page use the same rule', () {
    for (final path in [
      'lib/features/dashboard/dashboard_screen.dart',
      'lib/features/children/child_detail_screen.dart',
    ]) {
      final source = File(path).readAsStringSync();
      expect(source, contains('isDeviceOnline(d.lastSeen)'), reason: path);
      expect(source, isNot(contains('Duration(minutes: 3)')), reason: path);
    }
  });
}
