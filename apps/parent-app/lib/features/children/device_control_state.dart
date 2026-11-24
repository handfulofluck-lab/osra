import '../../api/models.dart';

/// What the child card says about *this* handset's last per-device command (#969).
///
/// The card has two groups of controls: the ones that address a single handset (pause, resume, lock, unlock,
/// ring, stop ring) and the internet control, which addresses the family. Scope labels name the difference, and
/// this decides which status line sits under the per-handset group.
///
/// The line exists because a queued command is not a done command: the POST answers `{status: pending}` before
/// the handset has seen it, and a refused or failed command leaves the parent looking at a button that appears to
/// have worked. [pending] and [failed] use the Arabic Language Bureau's own wording for the per-device case, which
/// is deliberately not the command-history wording (`statusPending`/`statusFailed`): the history keys describe a
/// delivery state, while these name the device the parent is looking at (Bureau, 604 `7116638057`).
enum DeviceControlLine { none, pending, failed }

/// The command types the line follows: the ones sent to one handset, never the family-wide internet control.
const Set<String> perDeviceCommandTypes = {'pause', 'resume', 'lock', 'unlock', 'ring', 'stop_ring'};

/// Reads the newest per-device command out of the history and says which line, if any, the card shows.
///
/// One command decides, not the set: a parent who paused and then locked should see the state of the newest
/// thing they asked for, not the residue of an older one. Commands that are still travelling are `pending`;
/// a `failed` command is `failed`; `acked`, `expired` and anything unknown are silent, because a delivered-and-
/// acknowledged command needs no line and an expired one is answered by the delivery summary that already
/// sits above.
DeviceControlLine deviceControlLine(Iterable<DeviceCommand> history) {
  DeviceCommand? newest;
  for (final command in history) {
    if (!perDeviceCommandTypes.contains(command.type)) continue;
    final created = command.createdAt;
    if (newest == null) {
      newest = command;
      continue;
    }
    final newestCreated = newest.createdAt;
    if (created == null) continue;
    if (newestCreated == null || created.isAfter(newestCreated)) newest = command;
  }
  final status = newest?.status;
  switch (status) {
    case 'pending':
    case 'delivered':
      return DeviceControlLine.pending;
    case 'failed':
      return DeviceControlLine.failed;
    default:
      return DeviceControlLine.none;
  }
}
