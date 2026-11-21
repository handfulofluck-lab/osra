import 'package:familyshield_parent/api/models.dart';
import 'package:familyshield_parent/features/children/internet_state.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_api_client.dart';

/// #969: the dashboard chip could only say "paused" or not, because the status endpoint reports what was
/// requested. These rows pin the four states a parent can actually be told, from the fixture rows the queue
/// already produces.
///
/// The labels are the Bureaus' and are not in this file: the state is derived here, and the words are wired in
/// when #650 `7051817882` and #604 answer.
void main() {
  final now = DateTime.now();

  DeviceCommand row(String status, {String type = 'pause_internet', int minutesAgo = 0}) =>
      DeviceCommand.fromJson(commandJson('c-$status-$type-$minutesAgo', type, status,
          now.subtract(Duration(minutes: minutesAgo))));

  group('internetStateFor', () {
    test('no request means inactive, whatever the devices say', () {
      expect(internetStateFor(requested: false, newestPerDevice: [row('acked')]), InternetState.inactive);
    });

    test('a request no device has acknowledged is waiting', () {
      expect(internetStateFor(requested: true, newestPerDevice: [row('pending')]), InternetState.waiting);
      expect(internetStateFor(requested: true, newestPerDevice: [row('delivered')]), InternetState.waiting);
    });

    test('delivered is not confirmed: the phone fetched it, it did not act', () {
      expect(internetStateFor(requested: true, newestPerDevice: [row('delivered'), row('delivered')]),
          InternetState.waiting);
    });

    test('every device acknowledged is confirmed', () {
      expect(internetStateFor(requested: true, newestPerDevice: [row('acked'), row('acked')]),
          InternetState.confirmed);
    });

    test('a mixed result stays visible as partial', () {
      expect(internetStateFor(requested: true, newestPerDevice: [row('acked'), row('pending')]),
          InternetState.partial);
    });

    test('a refusal with nothing acknowledged is partial, never waiting', () {
      expect(internetStateFor(requested: true, newestPerDevice: [row('failed'), row('pending')]),
          InternetState.partial);
    });

    // Antigravity's F1 (7052763165): the command TYPE has to match the action that was requested. An acked
    // `resume_internet` says the opposite of "internet paused", so it can never confirm a pause.
    test('an acknowledged resume does not confirm a pause', () {
      expect(
        internetStateFor(requested: true, newestPerDevice: [row('acked', type: 'resume_internet')]),
        InternetState.waiting,
        reason: 'the only acknowledged command did the opposite of what was requested',
      );
    });

    test('one device paused and one still on its old resume is partial, never confirmed', () {
      expect(
        internetStateFor(requested: true, newestPerDevice: [
          row('acked'),
          row('acked', type: 'resume_internet', minutesAgo: 5),
        ]),
        InternetState.partial,
        reason: 'the second device has no row for the pause request, so it is unknown, not confirmed',
      );
    });

    // Antigravity's F2 (7056262604): a device with no row for the request is UNKNOWN, and must stay in the list
    // as a null entry. Dropping it shortens the list and lets the remaining devices round the answer up.
    test('a device with no row for the request keeps it partial, not confirmed', () {
      expect(
        internetStateFor(requested: true, newestPerDevice: [row('acked'), null]),
        InternetState.partial,
        reason: 'one phone answered, one never received the request: that is not success',
      );
    });

    test('a null entry alone is waiting, never confirmed', () {
      expect(internetStateFor(requested: true, newestPerDevice: [null]),
          InternetState.waiting);
    });

    test('no devices at all is waiting, never confirmed', () {
      expect(internetStateFor(requested: true, newestPerDevice: const []), InternetState.waiting);
    });
  });

  group('newestInternetCommand', () {
    test('picks the newest pause or resume row and ignores other commands', () {
      final history = [
        row('acked', type: 'pause_internet', minutesAgo: 30),
        row('pending', type: 'resume_internet', minutesAgo: 2),
        row('acked', type: 'lock', minutesAgo: 1),
      ];
      final newest = newestInternetCommand(history);
      expect(newest?.type, 'resume_internet');
      expect(newest?.status, 'pending');
    });

    test('null when the device has no internet command, so unknown is not read as waiting', () {
      expect(newestInternetCommand([row('acked', type: 'lock')]), isNull);
      expect(newestInternetCommand(const []), isNull);
    });
  });
}
