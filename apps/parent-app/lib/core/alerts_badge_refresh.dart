import 'dart:async';

import 'bounded_refetch.dart';

/// #1056: how often the bell count is re-read while the app is in the foreground. One `GET /v1/alerts` per
/// two minutes is 30 requests an hour for a parent who leaves the app open, and nothing at all while the app
/// is backgrounded — the socket covers the realtime case, this only covers a socket that died without
/// reconnecting or a server that committed a row after its frame.
const Duration kAlertsBadgePollInterval = Duration(seconds: 120);

/// Keeps the unacknowledged-alert count fresh on the signals that mean it has probably changed but that never
/// arrive as a realtime frame: a push wake, the app returning to the foreground, and — as a fallback — a slow
/// poll while the app is foreground.
///
/// A background push cannot refresh this: it is handled in a separate isolate that posts a local notification
/// and has no access to the widget tree's state. The chain is therefore "push posts the notification, resume
/// refetches", which is why resume is not optional here.
///
/// Kept as its own class beside [BoundedRefetch] so the behaviour has rows of its own: the mutants are
/// "drop the resume read", "poll while backgrounded" and "poll never starts", and each is a unit test rather
/// than a widget tree.
class AlertsBadgeRefresh {
  AlertsBadgeRefresh({
    required this.refresh,
    this.refetchDelay = kAlertRefetchDelay,
    this.pollInterval = kAlertsBadgePollInterval,
  });

  final void Function() refresh;
  final Duration refetchDelay;
  final Duration pollInterval;

  late final BoundedRefetch _refetch = BoundedRefetch(run: refresh, delay: refetchDelay);
  Timer? _poll;

  /// A push wake. Reads now and once more after [refetchDelay]: the push can be sent before its alert row is
  /// committed, the same race #1145 fixed for the realtime frame.
  void onPush() => _refetch.schedule();

  /// The app came to the foreground: read once now, then keep the fallback poll running.
  void onResume() {
    _refetch.schedule();
    _poll?.cancel();
    _poll = Timer.periodic(pollInterval, (_) => refresh());
  }

  /// The app went to the background: stop the poll. Nothing polls a phone in a pocket.
  void onPause() {
    _poll?.cancel();
    _poll = null;
  }

  /// True while the fallback poll is running, so a caller can tell an idle instance from a working one.
  bool get polling => _poll != null;

  void dispose() {
    _refetch.cancel();
    onPause();
  }
}
