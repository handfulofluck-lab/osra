import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Issue #742, Ahmed's #1121 review: the `acknowledgeFromNotification` exemption is for a notification action,
/// where the parent already chose it from the shade. The two in-app acknowledge taps are **not** that, and
/// carrying the marker there let a child holding an unlocked parent phone acknowledge away a tamper, SOS or
/// device-PIN alert with no owner prompt — hiding exactly the detection the parent relies on.
///
/// Read as text, the technique the Kotlin wiring tests use: it proves no call site carries the marker. The
/// semantics of the marker itself are `mutation_auth_test.dart`.
///
/// Mutant: put the marker back on either in-app ack and this row goes red.
void main() {
  test('no in-app acknowledge carries the notification exemption', () {
    for (final path in <String>[
      'lib/features/alerts/alerts_screen.dart',
      'lib/features/children/child_detail_screen.dart',
    ]) {
      final source = File(path).readAsStringSync();
      expect(
        source.contains('acknowledgeFromNotification'),
        isFalse,
        reason: '$path is an in-app tap: it must ask the owner, not reuse the notification exemption',
      );
    }
  });

  test('the exemption is kept for the notification action, not deleted from the policy', () {
    // The marker still names exactly one endpoint; if a real notification action lands it uses this, and if
    // the team decides no such action will exist, it is removed with its rows rather than left unmarked here.
    final policy = File('lib/core/mutation_auth.dart').readAsStringSync();
    expect(policy.contains("ack-from-notification"), isTrue);
  });
}
