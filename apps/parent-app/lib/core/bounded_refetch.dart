import 'dart:async';

/// How long after a realtime `alert` event the parent app re-reads the unread count. The alert row can be
/// committed after its own WebSocket frame, so a single refetch on the event can read the previous set and
/// leave the badge stale until something else happens (#1056).
const Duration kAlertRefetchDelay = Duration(seconds: 3);

/// Runs [run] now and once more after [delay], so an event that arrives before its row is readable still ends
/// with a fresh read. Bounded on purpose: one extra read per event, not a poll.
///
/// Kept as its own class because the behaviour is what needs a row: the mutant is "drop the second run", and a
/// timer buried inside a provider cannot be tested without a widget tree.
class BoundedRefetch {
  BoundedRefetch({required this.run, this.delay = kAlertRefetchDelay});

  final void Function() run;
  final Duration delay;

  /// True once [schedule] has been called, so a caller can tell an idle instance from a working one.
  bool get scheduled => _timer != null;

  Timer? _timer;

  void schedule() {
    run();
    _timer?.cancel();
    _timer = Timer(delay, () {
      _timer = null;
      run();
    });
  }

  /// Cancels a pending second read. Called when the owner goes away, so no callback fires into a disposed
  /// container.
  void cancel() {
    _timer?.cancel();
    _timer = null;
  }
}
