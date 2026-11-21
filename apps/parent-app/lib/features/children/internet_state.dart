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

/// Which of [InternetState] describes [requested] given one row per device ([newestPerDevice]).
///
/// **What the caller must pass** (Codex, `7056040915`): one entry **per device**, holding the row belonging to the
/// **latest Pause or Resume request** — identified by the command ids the aggregate returns — or `null` when that
/// device has no row for it. `null` entries must be kept: dropping them shortens the list, and a child with two
/// phones where one never answered would read as `confirmed`. A device's *newest* row is only a stopgap —
/// `newestInternetCommand` below — and it is the weaker reading: on a cold device its newest internet row can
/// belong to an older request, which is why the aggregate ties its answer to command ids rather than to time.
///
/// Only an `acked` row counts as confirmed: `delivered` means the phone fetched the command, not that it acted,
/// and `failed`/`expired` mean the opposite of confirmed. An empty list is `waiting`, never `confirmed` — a
/// child with no devices, or a phone that has not reported, must not read as success.
InternetState internetStateFor({
  required bool requested,
  required List<DeviceCommand?> newestPerDevice,
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
    if (command == null) continue;   // a device with no row for this request is unknown, not confirmed
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

/// The newest `pause_internet`/`resume_internet` row for one device, taken from that device's history.
///
/// **A stopgap, not the contract.** It reads time, not request identity, so a device whose newest internet row
/// belongs to an older Pause/Resume reports that older answer. The aggregate Codex is building returns the
/// command ids of the latest request, which is the correct input for [internetStateFor]; this helper keeps the
/// screen usable until that lands, and nothing should be built on top of it that assumes request identity.
///
/// Returns null when that device has neither, so the caller can tell "this device has no row yet" from "its
/// newest row says pending". The first is unknown and still belongs in the list [internetStateFor] reads, **as a
/// null entry** — omitting it would let the remaining devices round the answer up.
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
