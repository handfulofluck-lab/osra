import 'package:flutter_test/flutter_test.dart';

import 'package:familyshield_parent/api/models.dart';
import 'package:familyshield_parent/providers/family_provider.dart';

/// #760 follow-up, Codex `7158872749`: when a newer ring has started and its acknowledgement is late, **Stop** must
/// target that ring, not an older one that has already been acknowledged. History arrives newest first.
void main() {
  DeviceCommand command(String id, String status, {String type = 'ring'}) => DeviceCommand(
        id: id,
        deviceId: 'dev-1',
        type: type,
        status: status,
        createdAt: DateTime.utc(2026, 11, 24, 10),
        expiresAt: null,
        deliveredAt: null,
        ackedAt: null,
        attempts: 1,
        result: null,
      );

  test('a started ring with a late ack wins over an older acknowledged ring', () {
    final history = [command('ring-new', 'delivered'), command('ring-old', 'acked')];
    expect(activeRingId(history), 'ring-new',
        reason: 'Stop must aim at the ring that is ringing, not one the device already settled');
  });

  test('a pending ring is the one being sent, so it is the one Stop targets', () {
    expect(activeRingId([command('ring-new', 'pending'), command('ring-old', 'delivered')]), 'ring-new');
  });

  test('no history targets nothing', () {
    expect(activeRingId(const []), isNull);
  });

  test('a failed newer ring does not displace the ring the device applied', () {
    final history = [command('ring-new', 'failed'), command('ring-old', 'acked')];
    expect(activeRingId(history), 'ring-old',
        reason: 'a failed row is not ringing, and the applied ring is still the one the child can finish');
  });

  test('a failed newer ring still loses to a live one behind it', () {
    expect(activeRingId([command('ring-new', 'failed'), command('ring-old', 'delivered')]), 'ring-old');
  });

  test('an expired newer ring is skipped for the live one behind it', () {
    expect(activeRingId([command('ring-new', 'expired'), command('ring-old', 'delivered')]), 'ring-old');
  });

  test('other commands are ignored even when they are live', () {
    expect(activeRingId([command('lock-1', 'delivered', type: 'lock'), command('ring-1', 'delivered')]),
        'ring-1');
  });
}
