import 'package:familyshield_parent/features/children/internet_state.dart';
import 'package:flutter_test/flutter_test.dart';

/// #969: the dashboard chip could only say "paused" or not, because it read `paused` — whether the command was
/// sent. The aggregate (`services/api/src/lib/childInternet.ts`) now answers per device for **this** request,
/// and these rows pin the four states a parent can actually be told.
///
/// The statuses below are the server's own vocabulary: `pending`, `delivered`, `acked`, `failed`, `expired`,
/// `unconfirmed` (the window closed while the phone held the command) and `unknown` (that device was not on the
/// request). The labels are the Bureaus' and are not in this file.
void main() {
  group('internetStateFor', () {
    test('no request means inactive, whatever the devices said', () {
      expect(internetStateFor(paused: false, deviceStatuses: ['acked']), InternetState.inactive);
      expect(internetStateFor(paused: false, deviceStatuses: const []), InternetState.inactive);
    });

    test('a request nothing has settled is waiting', () {
      expect(internetStateFor(paused: true, deviceStatuses: ['pending']), InternetState.waiting);
      expect(internetStateFor(paused: true, deviceStatuses: ['delivered', 'pending']),
          InternetState.waiting);
    });

    test('unknown devices alone are waiting, because nothing has happened yet', () {
      expect(internetStateFor(paused: true, deviceStatuses: ['unknown', 'unknown']),
          InternetState.waiting);
    });

    test('delivered is not confirmed: the phone fetched it, it did not act', () {
      expect(internetStateFor(paused: true, deviceStatuses: ['delivered', 'delivered']),
          InternetState.waiting);
    });

    test('every device acknowledged is confirmed', () {
      expect(internetStateFor(paused: true, deviceStatuses: ['acked', 'acked']), InternetState.confirmed);
    });

    test('one ack and one still pending is partial', () {
      expect(internetStateFor(paused: true, deviceStatuses: ['acked', 'pending']), InternetState.partial);
    });

    test('one ack and one device that was not on the request is partial, never confirmed', () {
      expect(internetStateFor(paused: true, deviceStatuses: ['acked', 'unknown']), InternetState.partial,
          reason: 'a phone that never received this request has not answered it');
    });

    test('a refusal with nothing acknowledged is partial, never waiting', () {
      expect(internetStateFor(paused: true, deviceStatuses: ['failed', 'pending']), InternetState.partial,
          reason: 'a parent must not be told to keep waiting on a phone that already said no');
    });

    // The server's word for "we asked, the window closed, the phone never said" — the case a client could not
    // detect on its own, and the one this state exists to stop hiding.
    test('unconfirmed is not waiting and not confirmed', () {
      expect(internetStateFor(paused: true, deviceStatuses: ['unconfirmed']), InternetState.partial);
      expect(internetStateFor(paused: true, deviceStatuses: ['acked', 'unconfirmed']),
          InternetState.partial);
    });

    test('expired counts the same as a refusal', () {
      expect(internetStateFor(paused: true, deviceStatuses: ['expired']), InternetState.partial);
    });

    test('no paired devices at all is waiting, never confirmed', () {
      expect(internetStateFor(paused: true, deviceStatuses: const []), InternetState.waiting);
    });
  });
}
