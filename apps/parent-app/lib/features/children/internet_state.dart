import '../../api/models.dart';

/// #969: what a parent can actually say about a child's internet pause.
///
/// The dashboard chip reads `GET /v1/controls/children/:id/status`, which reports whether the command was
/// **sent** (`controls.ts:25-59`). It has never reported whether a handset applied it, so a red "internet
/// paused" could sit over a phone that was still online — Codex's report, and the reason this type exists.
///
/// The per-device confirmation is already on the wire: `pause_internet` and `resume_internet` fan out as one
/// `DeviceCommand` per device with `pending → delivered → acked|failed|expired`. This maps one newest row per
/// device plus the requested flag into the only four things a parent can be told truthfully.
enum InternetState {
  /// No pause was requested, or the requested pause has been lifted.
  inactive,

  /// Requested, and no device has acknowledged it yet. Also the answer when a device's rows are unknown,
  /// because "we do not know yet" must not be shown as either outcome.
  waiting,

  /// Every device that reported has acknowledged the newest request.
  confirmed,

  /// Some acknowledged and some did not — including a device that has no row for the requested action at all —
  /// or nothing acknowledged and something failed. A mixed, unknown or refused result stays visible rather than
  /// being rounded to one side.
  partial,
}

/// Which of [InternetState] describes [requested] given the newest `pause_internet`/`resume_internet` row of
/// each device ([newestPerDevice]).
///
/// Only an `acked` row counts as confirmed: `delivered` means the phone fetched the command, not that it acted,
/// and `failed`/`expired` mean the opposite of confirmed. An empty list is `waiting`, never `confirmed` — a
/// child with no devices, or a phone that has not reported, must not read as success.
InternetState internetStateFor({
  required bool requested,
  required List<DeviceCommand> newestPerDevice,
}) {
  if (!requested) return InternetState.inactive;
  if (newestPerDevice.isEmpty) return InternetState.waiting;
  // Only a row for the action that was requested can say anything about it. A device whose newest internet row
  // is a `resume_internet` has not answered a pause request at all — counting it would report "confirmed" on the
  // strength of the command that did the opposite (Antigravity's F1, 7052763165).
  final expected = requested ? 'pause_internet' : 'resume_internet';
  var acked = 0;
  var settledWithoutAck = 0;
  for (final command in newestPerDevice) {
    if (command.type != expected) continue;
    if (command.status == 'acked') {
      acked++;
    } else if (command.status == 'failed' || command.status == 'expired') {
      settledWithoutAck++;
    }
  }
  // Confirmed means EVERY device acknowledged THIS request. A device with no row for it is not confirmed, so it
  // cannot be rounded away: with one ack and one unknown the parent sees `partial`, not success.
  if (acked == newestPerDevice.length) return InternetState.confirmed;
  if (acked > 0 || settledWithoutAck > 0) return InternetState.partial;
  return InternetState.waiting;
}

/// The newest `pause_internet`/`resume_internet` row per device, taken from one device's history.
///
/// Returns null when that device has neither, so the caller can tell "this device has no row yet" from "its
/// newest row says pending" — the first is unknown, the second is waiting, and only the second belongs in the
/// list [internetStateFor] reads.
DeviceCommand? newestInternetCommand(List<DeviceCommand> history) {
  DeviceCommand? newest;
  for (final command in history) {
    if (command.type != 'pause_internet' && command.type != 'resume_internet') continue;
    final previous = newest?.createdAt;
    if (newest == null || previous == null || (command.createdAt?.isAfter(previous) ?? false)) {
      newest = command;
    }
  }
  return newest;
}
