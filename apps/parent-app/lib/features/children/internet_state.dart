/// #969: what a parent can actually say about a child's internet pause.
///
/// The dashboard chip used to read only `paused` from `GET /v1/controls/children/:id/status`, which reports
/// whether the command was **sent**. That could sit red over a phone that was still online — Codex's report.
///
/// The aggregate now answers the question directly (`services/api/src/lib/childInternet.ts`,
/// `latestChildInternet`): the response carries `internetRequest.devices[]`, one entry per device **of this
/// request**, each with the status of its own command id. The server has already done the part a client cannot:
/// a device that never received this request comes back `unknown`, and a command whose window closed is
/// `expired` or `unconfirmed` rather than silently pending.
///
/// This file maps those statuses to the only four things a parent can be told truthfully. It reads no
/// timestamps and makes no guesses: the input *is* the answer to "what did each phone say about this request".
enum InternetState {
  /// No pause was requested, or the requested pause has been lifted.
  inactive,

  /// A device can still acknowledge the request, or the server has only reported the requested action.
  waiting,

  /// Every device on the request acknowledged it.
  confirmed,

  /// Some acknowledged and some did not, or nothing acknowledged and something failed, expired or was never
  /// confirmed. This also covers a server request with no device left to acknowledge it.
  partial,
}

/// Which of [InternetState] describes the latest request, given its action and one entry per device from
/// `internetRequest.devices`.
///
/// **[action] is the request's own action — `pause`, `resume`, or null when no request exists.** It is not the
/// same as `paused`: a resume can be pending, refused or unconfirmed just as a pause can, and calling that
/// "nothing is happening" would be the same false claim in the other direction (Codex, `7060793626`). Derive it
/// as `internetRequest?.action`, and fall back to `paused == true ? 'pause' : null` only for an older server —
/// that fallback carries no device statuses, so it can reach `waiting` but never `confirmed`.
///
/// **Only `acked` counts as confirmed.** `delivered` means the phone fetched the command, not that it acted.
/// `failed` and `expired` mean it did not. `unconfirmed` means the window closed while the phone held the
/// command — the server's own word for "we asked, it never said" — and `unknown` means this device was not on
/// the request at all. None of those may round up.
///
/// An empty list from a persisted server request has no confirmation path. Optimistic and legacy responses
/// also have empty lists, but only report the requested action and still show [InternetState.waiting].
InternetState internetStateFor({
  required String? action,
  required List<String> deviceStatuses,
  bool hasServerRequest = false,
}) {
  if (action == null) return InternetState.inactive;
  if (deviceStatuses.isEmpty) return hasServerRequest ? InternetState.partial : InternetState.waiting;
  var acked = 0;
  var settledWithoutAck = false;
  var canStillAcknowledge = false;
  for (final status in deviceStatuses) {
    if (status == 'acked') {
      acked++;
    } else if (status == 'failed' || status == 'expired' || status == 'unconfirmed') {
      settledWithoutAck = true;
    } else if (status == 'pending' || status == 'delivered') {
      canStillAcknowledge = true;
    }
  }
  if (acked == deviceStatuses.length) return InternetState.confirmed;
  if (acked > 0 || settledWithoutAck || !canStillAcknowledge) return InternetState.partial;
  return InternetState.waiting;
}
