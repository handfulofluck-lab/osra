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

  /// Requested, and no device has settled it yet — every entry is `pending`, `delivered` or `unknown`.
  waiting,

  /// Every device on the request acknowledged it.
  confirmed,

  /// Some acknowledged and some did not, or nothing acknowledged and something failed, expired or was never
  /// confirmed. A mixed, unknown or refused result stays visible rather than being rounded to one side.
  partial,
}

/// Which of [InternetState] describes the latest request, given one entry per device from
/// `internetRequest.devices`.
///
/// **Only `acked` counts as confirmed.** `delivered` means the phone fetched the command, not that it acted.
/// `failed` and `expired` mean it did not. `unconfirmed` means the window closed while the phone held the
/// command — the server's own word for "we asked, it never said" — and `unknown` means this device was not on
/// the request at all. None of those may round up.
///
/// An empty list is [InternetState.waiting], never `confirmed`: a child with no paired devices must not read as
/// success.
InternetState internetStateFor({
  required bool paused,
  required List<String> deviceStatuses,
}) {
  if (!paused) return InternetState.inactive;
  if (deviceStatuses.isEmpty) return InternetState.waiting;
  var acked = 0;
  var settledWithoutAck = 0;
  for (final status in deviceStatuses) {
    if (status == 'acked') {
      acked++;
    } else if (status == 'failed' || status == 'expired' || status == 'unconfirmed') {
      settledWithoutAck++;
    }
  }
  if (acked == deviceStatuses.length) return InternetState.confirmed;
  if (acked > 0 || settledWithoutAck > 0) return InternetState.partial;
  return InternetState.waiting;
}
