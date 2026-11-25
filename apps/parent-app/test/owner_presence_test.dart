import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_auth/local_auth.dart';

import 'package:familyshield_parent/core/mutation_auth.dart';
import 'package:familyshield_parent/core/owner_presence.dart';

/// Issue #742: the gate in front of every mutation. These rows are about *who is asked* and *what happens when
/// the answer is no*; the endpoint binding itself is pinned in `mutation_auth_test.dart`.
///
/// Mutants are named on each row so a future edit that quietly re-opens the gate fails loudly.
void main() {
  group('guardMutation — the owner is asked only when the policy says so', () {
    test('a read is never asked about', () async {
      var asked = 0;
      await guardMutation(
        method: 'GET',
        path: '/v1/rules',
        exempt: null,
        askOwner: (_) async {
          asked++;
          return OwnerPresence.authorised;
        },
        reason: 'r',
      );
      expect(asked, 0);
    });

    test('an unmarked mutation is asked once and proceeds only on authorised', () async {
      var asked = 0;
      await guardMutation(
        method: 'POST',
        path: '/v1/rules',
        exempt: null,
        askOwner: (_) async {
          asked++;
          return OwnerPresence.authorised;
        },
        reason: 'r',
      );
      expect(asked, 1);
    });

    test('a cancelled prompt throws, and the result says why', () async {
      await expectLater(
        guardMutation(
          method: 'POST',
          path: '/v1/rules',
          exempt: null,
          askOwner: (_) async => OwnerPresence.cancelled,
          reason: 'r',
        ),
        throwsA(isA<OwnerPresenceRequired>().having((e) => e.result, 'result', OwnerPresence.cancelled)),
      );
    });

    test('a phone with no lock is refused, not downgraded to the app PIN', () async {
      // Claude's ruling: refuse, never fall back. The UI tells the two failures apart from `result`.
      await expectLater(
        guardMutation(
          method: 'DELETE',
          path: '/v1/family/children/1',
          exempt: null,
          askOwner: (_) async => OwnerPresence.unavailable,
          reason: 'r',
        ),
        throwsA(isA<OwnerPresenceRequired>().having((e) => e.result, 'result', OwnerPresence.unavailable)),
      );
    });

    test('a marker frees its own endpoint without asking', () async {
      var asked = 0;
      await guardMutation(
        method: 'POST',
        path: '/v1/alerts/9/ack',
        exempt: AuthExempt.acknowledgeFromNotification,
        askOwner: (_) async {
          asked++;
          return OwnerPresence.authorised;
        },
        reason: 'r',
      );
      expect(asked, 0);
    });

    test('a marker on another endpoint is asked, not trusted', () async {
      // Mutant: `if (exempt != null) return;` — the unbound marker Ahmed rejected on #1114.
      var asked = 0;
      await expectLater(
        guardMutation(
          method: 'POST',
          path: '/v1/controls/children/1/pause',
          exempt: AuthExempt.pushToken,
          askOwner: (_) async {
            asked++;
            return OwnerPresence.cancelled;
          },
          reason: 'r',
        ),
        throwsA(isA<OwnerPresenceRequired>()),
      );
      expect(asked, 1);
    });

    test('a string where a marker belongs is not a marker', () async {
      // Mutant: accepting `Object` and treating any non-null `extra` as an exemption.
      await expectLater(
        guardMutation(
          method: 'POST',
          path: '/v1/rules',
          exempt: 'push-token',
          askOwner: (_) async => OwnerPresence.cancelled,
          reason: 'r',
        ),
        throwsA(isA<OwnerPresenceRequired>()),
      );
    });

    test('signing out is exempt, so a phone with no lock can still leave', () async {
      var asked = 0;
      await guardMutation(
        method: 'POST',
        path: '/v1/auth/logout',
        exempt: AuthExempt.sessionEnd,
        askOwner: (_) async {
          asked++;
          return OwnerPresence.authorised;
        },
        reason: 'r',
      );
      expect(asked, 0);
    });

    test('logout-all is not the session-end endpoint', () async {
      // Ahmed's condition on the fourth exemption: the single-device logout is exempt, the everywhere one is not.
      await expectLater(
        guardMutation(
          method: 'POST',
          path: '/v1/auth/logout-all',
          exempt: AuthExempt.sessionEnd,
          askOwner: (_) async => OwnerPresence.cancelled,
          reason: 'r',
        ),
        throwsA(isA<OwnerPresenceRequired>()),
      );
    });
  });

  group('OwnerPresenceGate — the plugin is translated, not trusted', () {
    OwnerPresenceGate gate({
      bool supported = true,
      bool answer = false,
      LocalAuthException? error,
      LocalAuthException? supportedError,
    }) =>
        OwnerPresenceGate.forTest(
          isSupported: () async {
            if (supportedError != null) throw supportedError;
            return supported;
          },
          authenticate: (_) async {
            if (error != null) throw error;
            return answer;
          },
        );

    test('a supported device that accepts is authorised', () async {
      expect(await gate(answer: true).authorise('r'), OwnerPresence.authorised);
    });

    test('a supported device that refuses is cancelled', () async {
      expect(await gate(answer: false).authorise('r'), OwnerPresence.cancelled);
    });

    test('a device with no lock at all is unavailable', () async {
      // Mutant: calling the prompt anyway and treating its error as "cancelled" would send the parent to a
      // retry loop instead of the "set a screen lock" path.
      expect(await gate(supported: false, answer: true).authorise('r'), OwnerPresence.unavailable);
    });

    test("the plugin's no-credentials answer is unavailable, not a failed attempt", () async {
      expect(
        await gate(error: const LocalAuthException(code: LocalAuthExceptionCode.noCredentialsSet)).authorise('r'),
        OwnerPresence.unavailable,
      );
    });

    test('a system-cancelled prompt is a failed attempt, so the parent is asked again', () async {
      expect(
        await gate(error: const LocalAuthException(code: LocalAuthExceptionCode.systemCanceled)).authorise('r'),
        OwnerPresence.cancelled,
      );
    });

    test('an unlisted future code falls to cancelled rather than trapping the parent', () async {
      expect(
        await gate(error: const LocalAuthException(code: LocalAuthExceptionCode.authInProgress)).authorise('r'),
        OwnerPresence.cancelled,
      );
    });

    test('a thrown device-support check is unavailable, never an exception up the call stack', () async {
      expect(
        await gate(supportedError: const LocalAuthException(code: LocalAuthExceptionCode.uiUnavailable)).authorise('r'),
        OwnerPresence.unavailable,
      );
    });

    test('an old platform exception is treated as a failed attempt', () async {
      final legacy = OwnerPresenceGate.forTest(
        isSupported: () async => true,
        authenticate: (_) async => throw PlatformException(code: 'Lockout'),
      );
      expect(await legacy.authorise('r'), OwnerPresence.cancelled);
    });
  });
}
