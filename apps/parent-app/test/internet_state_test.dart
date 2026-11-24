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
      expect(internetStateFor(action: null, deviceStatuses: ['acked']), InternetState.inactive);
      expect(internetStateFor(action: null, deviceStatuses: const []), InternetState.inactive);
    });

    // Codex (7060793626): a resume is a request like any other. Calling it "inactive" while the phone has not
    // acknowledged it is the same false claim as calling a pending pause confirmed — in the other direction.
    group('a resume is a request too', () {
      test('pending resume is waiting, not inactive', () {
        expect(internetStateFor(action: 'resume', deviceStatuses: ['pending']), InternetState.waiting);
      });

      test('failed resume is partial, not inactive', () {
        expect(internetStateFor(action: 'resume', deviceStatuses: ['failed']), InternetState.partial);
      });

      test('unconfirmed resume is partial, not inactive', () {
        expect(internetStateFor(action: 'resume', deviceStatuses: ['unconfirmed']), InternetState.partial);
      });

      test('acknowledged resume is confirmed', () {
        expect(internetStateFor(action: 'resume', deviceStatuses: ['acked', 'acked']),
            InternetState.confirmed);
      });

      test('a legacy fallback with no device statuses never claims confirmation', () {
        // An older server sends `paused` and no internetRequest; the caller falls back to action 'pause' with an
        // empty list, which is waiting — never confirmed.
        expect(internetStateFor(action: 'pause', deviceStatuses: const []), InternetState.waiting);
      });
    });

    test('a request nothing has settled is waiting', () {
      expect(internetStateFor(action: 'pause', deviceStatuses: ['pending']), InternetState.waiting);
      expect(internetStateFor(action: 'pause', deviceStatuses: ['delivered', 'pending']),
          InternetState.waiting);
    });

    test('unknown devices alone are waiting, because nothing has happened yet', () {
      expect(internetStateFor(action: 'pause', deviceStatuses: ['unknown', 'unknown']),
          InternetState.waiting);
    });

    test('delivered is not confirmed: the phone fetched it, it did not act', () {
      expect(internetStateFor(action: 'pause', deviceStatuses: ['delivered', 'delivered']),
          InternetState.waiting);
    });

    test('every device acknowledged is confirmed', () {
      expect(internetStateFor(action: 'pause', deviceStatuses: ['acked', 'acked']), InternetState.confirmed);
    });

    test('one ack and one still pending is partial', () {
      expect(internetStateFor(action: 'pause', deviceStatuses: ['acked', 'pending']), InternetState.partial);
    });

    test('one ack and one device that was not on the request is partial, never confirmed', () {
      expect(internetStateFor(action: 'pause', deviceStatuses: ['acked', 'unknown']), InternetState.partial,
          reason: 'a phone that never received this request has not answered it');
    });

    test('a refusal with nothing acknowledged is partial, never waiting', () {
      expect(internetStateFor(action: 'pause', deviceStatuses: ['failed', 'pending']), InternetState.partial,
          reason: 'a parent must not be told to keep waiting on a phone that already said no');
    });

    // The server's word for "we asked, the window closed, the phone never said" — the case a client could not
    // detect on its own, and the one this state exists to stop hiding.
    test('unconfirmed is not waiting and not confirmed', () {
      expect(internetStateFor(action: 'pause', deviceStatuses: ['unconfirmed']), InternetState.partial);
      expect(internetStateFor(action: 'pause', deviceStatuses: ['acked', 'unconfirmed']),
          InternetState.partial);
    });

    test('expired counts the same as a refusal', () {
      expect(internetStateFor(action: 'pause', deviceStatuses: ['expired']), InternetState.partial);
    });

    test('no paired devices at all is waiting, never confirmed', () {
      expect(internetStateFor(action: 'pause', deviceStatuses: const []), InternetState.waiting);
    });
  });
}
