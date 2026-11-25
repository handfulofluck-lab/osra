import 'package:flutter_test/flutter_test.dart';

import 'package:familyshield_parent/api/models.dart';
import 'package:familyshield_parent/providers/family_provider.dart';

/// Stop must name the **newest** ring that reached `pending`, `delivered` or `acked`. A child acks a ring when it
/// *starts* sounding, so `acked` is an actively ringing command, not a finished one; history is newest first. Two
/// findings pin this: Codex `7158872749` (a newer ring with its ack in flight) and Antigravity `7164117097` (scanning
/// past a newer acked row returned a stale id the child refuses).
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
        reason: 'Stop must aim at the ring that is ringing, not one that was superseded');
  });

  test('a newer ringing ring outranks an older superseded one, and is not skipped', () {
    // Antigravity #1125: [acked(new), delivered(old)] returned the OLD id, which the child refuses as
    // invalid_command while the phone kept ringing.
    expect(activeRingId([command('ring-new', 'acked'), command('ring-old', 'delivered')]), 'ring-new');
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
