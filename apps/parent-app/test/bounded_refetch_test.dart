import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:familyshield_parent/core/bounded_refetch.dart';

/// Issue #1056: an `alert` frame can be handled before its row is readable, so the unread count read on the
/// event returns the previous set and the badge stays stale. These rows pin the bounded second read — the
/// mutant each one kills is written beside it.
void main() {
  test('an alert event reads now and once more after the delay', () {
    fakeAsync((async) {
      var runs = 0;
      final refetch = BoundedRefetch(run: () => runs++, delay: const Duration(seconds: 2));
      refetch.schedule();
      expect(runs, 1, reason: 'the event still reads immediately');
      async.elapse(const Duration(seconds: 1));
      expect(runs, 1, reason: 'nothing before the delay');
      async.elapse(const Duration(seconds: 2));
      expect(runs, 2, reason: 'the second read is what closes the race');
    });
  });

  test('it stays bounded: no third read, ever', () {
    // Mutant: a periodic timer instead of one delayed read — three reads per event would be a poll that
    // costs a request every few seconds for as long as the app lives.
    fakeAsync((async) {
      var runs = 0;
      final refetch = BoundedRefetch(run: () => runs++, delay: const Duration(seconds: 2));
      refetch.schedule();
      async.elapse(const Duration(minutes: 5));
      expect(runs, 2);
    });
  });

  test('a second event replaces the pending read instead of stacking', () {
    // Mutant: scheduling a second timer without cancelling the first — two events in quick succession cost
    // three reads and the older timer fires after the newer one.
    fakeAsync((async) {
      var runs = 0;
      final refetch = BoundedRefetch(run: () => runs++, delay: const Duration(seconds: 2));
      refetch.schedule();
      async.elapse(const Duration(seconds: 1));
      refetch.schedule();
      expect(runs, 2);
      async.elapse(const Duration(seconds: 2));
      expect(runs, 3, reason: 'exactly one pending read, not two');
    });
  });

  test('cancel stops the pending read, so a disposed owner is not called into', () {
    fakeAsync((async) {
      var runs = 0;
      final refetch = BoundedRefetch(run: () => runs++, delay: const Duration(seconds: 2));
      refetch.schedule();
      refetch.cancel();
      async.elapse(const Duration(seconds: 10));
      expect(runs, 1);
      expect(refetch.scheduled, isFalse);
    });
  });
}
