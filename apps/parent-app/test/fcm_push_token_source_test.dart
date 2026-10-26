import 'package:flutter_test/flutter_test.dart';

import 'package:familyshield_parent/push/fcm_push_token_source.dart';
import 'package:familyshield_parent/push/push_registration.dart';

/// #360: the FCM source has to distinguish three facts that look alike from the outside —
/// **no config in this build**, **the parent refused**, and **granted but no token yet** —
/// because only the second is a decision the app must not re-ask.
///
/// The unit tests run with no Firebase config, which is exactly the shape of a build made from a
/// clean clone: `Firebase.initializeApp()` has nothing to read, so the source must report
/// `unavailable` rather than `denied` and must never throw.
void main() {
  group('FcmPushTokenSource without Firebase config', () {
    test('reports unavailable, never denied, when initialisation fails', () async {
      final source = FcmPushTokenSource(ensureInitialized: () async => throw StateError('no config'));
      expect(await source.requestPermission(), PushPermission.unavailable);
    });

    test('mints no token when initialisation fails', () async {
      final source = FcmPushTokenSource(ensureInitialized: () async => throw StateError('no config'));
      expect(await source.token(), isNull);
    });

    test('pays for the failed initialisation once, not on every call', () async {
      var attempts = 0;
      final source = FcmPushTokenSource(ensureInitialized: () async {
        attempts++;
        throw StateError('no config');
      });
      await source.requestPermission();
      await source.token();
      await source.requestPermission();
      // Mutant: drop the `_failed` latch and this is 3 — one failed Firebase init per poll.
      expect(attempts, 1);
    });
  });
}
