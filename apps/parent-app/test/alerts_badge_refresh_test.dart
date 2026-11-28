import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:familyshield_parent/core/alerts_badge_refresh.dart';

/// Issue #1056: the bell badge read the server count only on a realtime frame, so a push wake and a resume
/// left it stale. These rows pin the three triggers and the cost of the fallback; the mutant each one kills is
/// written beside it.
///
/// Counting note, so the numbers below are checkable: every trigger that goes through the bounded refetch
/// contributes **two** reads (one now, one after the 2 s delay used here), and each poll tick contributes one.
void main() {
  AlertsBadgeRefresh build(void Function() onRefresh, {Duration poll = const Duration(seconds: 120)}) =>
      AlertsBadgeRefresh(refresh: onRefresh, refetchDelay: const Duration(seconds: 2), pollInterval: poll);

  test('a push wake reads now and once more after the delay', () {
    // Mutant: a single read on the push — the push can be sent before its alert row is committed, so the
    // count read on the wake is the previous one.
    fakeAsync((async) {
      var reads = 0;
      final badge = build(() => reads++);
      badge.onPush();
      expect(reads, 1);
      async.elapse(const Duration(seconds: 1));
      expect(reads, 1);
      async.elapse(const Duration(seconds: 1));
      expect(reads, 2, reason: 'the bounded second read closes the push/row race');
      badge.dispose();
    });
  });

  test('resume reads immediately and then keeps a 120 s poll running', () {
    // Mutant: no poll at all — a socket that died without reconnecting leaves the badge stale for the whole
    // session, which is the reported symptom.
    fakeAsync((async) {
      var reads = 0;
      final badge = build(() => reads++);
      badge.onResume();
      expect(reads, 1, reason: 'the resume itself reads once');
      expect(badge.polling, isTrue);
      async.elapse(const Duration(seconds: 120));
      // The bounded second read (at 2 s) and the first poll tick (at 120 s).
      expect(reads, 3);
      async.elapse(const Duration(seconds: 120));
      expect(reads, 4, reason: 'one read per tick after the first');
      badge.dispose();
    });
  });

  test('the poll costs 30 reads an hour while foreground, and the interval is pinned', () {
    // The number in the PR, the changelog and here are the same one; this row fails if the interval drifts
    // without the cost being restated.
    expect(kAlertsBadgePollInterval, const Duration(seconds: 120));
    fakeAsync((async) {
      var reads = 0;
      final badge = build(() => reads++);
      badge.onResume();
      async.elapse(const Duration(hours: 1));
      // 1 on resume + 1 bounded second read + 30 ticks at two minutes.
      expect(reads, 32);
      badge.dispose();
    });
  });

  test('pause stops the poll: nothing polls a phone in a pocket', () {
    // Mutant: leaving the timer running when backgrounded — 30 requests an hour from an app nobody is looking
    // at, and the OS may suspend the isolate mid-timer anyway.
    fakeAsync((async) {
      var reads = 0;
      final badge = build(() => reads++);
      badge.onResume();
      async.elapse(const Duration(seconds: 120));
      expect(reads, 3);
      badge.onPause();
      expect(badge.polling, isFalse);
      async.elapse(const Duration(minutes: 10));
      expect(reads, 3, reason: 'no read after pause');
      badge.dispose();
    });
  });

  test('resume twice keeps exactly one poll, not two', () {
    // Mutant: replacing the timer without cancelling — two periodic timers means the fallback costs double,
    // which the hour-cost row above would not catch because that one resumes once.
    fakeAsync((async) {
      var reads = 0;
      final badge = build(() => reads++);
      badge.onResume();
      badge.onResume();
      async.elapse(const Duration(seconds: 120));
      // Two resume reads, one surviving bounded read (the second replaced the first's timer), one tick.
      expect(reads, 4);
      badge.dispose();
    });
  });

  test('startPolling starts the timer without reading anything', () {
    // Mutant: make startPolling reuse onResume — a cold start would then read the count twice (the mount's own
    // read plus this one), which the wiring row also forbids.
    fakeAsync((async) {
      var reads = 0;
      final badge = build(() => reads++);
      badge.startPolling();
      expect(reads, 0, reason: 'no immediate read');
      expect(badge.polling, isTrue);
      async.elapse(const Duration(seconds: 120));
      expect(reads, 1);
      badge.dispose();
    });
  });

  test('dispose stops the pending read and the poll, so a disposed owner is not called into', () {
    fakeAsync((async) {
      var reads = 0;
      final badge = build(() => reads++);
      badge.onResume();
      expect(reads, 1);
      badge.dispose();
      expect(badge.polling, isFalse);
      async.elapse(const Duration(minutes: 10));
      expect(reads, 1);
    });
  });
}
