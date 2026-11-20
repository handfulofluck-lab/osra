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
