import 'package:flutter_test/flutter_test.dart';

/// Child-escape catalogue PA01 (#738, `docs/testing/CHILD-ESCAPE-CATALOGUE.md` row PA01):
///
/// > App lock (#742) — open the parent app on the parent's unlocked phone and loosen a rule, unlink a device,
/// > pause protection, unblock an app or stop a ring — each of these asks for the parent's fingerprint, Face ID
/// > or device PIN first.
///
/// The catalogue also says PA01 is **a product decision for the maintainer** (#742), not something a test
/// author invents. So this row is written as a pending test: it states what passing would mean and why it
/// cannot be asserted yet, and it fails to run rather than pretending to pass.
///
/// When #742 lands, replace the skip with the real assertions — the shape is already here so the change is a
/// diff, not a new file.
void main() {
  test(
    'PA01: loosening a rule, unlinking a device, pausing protection, unblocking an app and stopping a ring '
    'each ask for biometrics or the device PIN before the change leaves the app',
    () {
      // The expected assertions, once #742 exists:
      //  1. each entry point shows the platform-authentication prompt before it calls the API;
      //  2. cancelling, a failed scan, Back, Home and backgrounding the prompt leave the rule unchanged and
      //     send nothing;
      //  3. the prompt is not cached: the second action asks again.
      fail('PA01 is a product decision (#742) and has no implementation to assert against yet.');
    },
    skip: 'Pending maintainer decision #742: the parent app has no app lock, so there is nothing to '
        'verify yet. Writing an assertion here would invent the feature instead of testing it.',
  );
}
