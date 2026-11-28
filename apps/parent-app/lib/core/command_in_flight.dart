/// One command POST at a time per child and command type.
///
/// Child-escape catalogue PA06 (#738, `docs/testing/CHILD-ESCAPE-CATALOGUE.md`):
///
/// > Double-tap ring/stop, lock/unlock fast, send while offline — exactly the last intent wins on the
/// > child; history shows each command once.
///
/// The parent app sent every tap as its own `POST /v1/devices/:id/command`: child detail and the family
/// map each had a plain sender with no in-flight guard, so a parent who tapped Ring twice queued two rings
/// and left two history rows. The guard is keyed by device **and** command, not by device alone, because
/// the row asks for each command once — a quick lock then unlock is two intents and must reach the child
/// as two, while the same command twice is one.
///
/// State lives at module level rather than in a widget, so the same command cannot be double-sent by
/// tapping Ring on the map and then on child detail while the first POST is still outstanding. Every
/// caller clears its key in a `finally`, so a failed or timed-out POST cannot wedge the control.
final Set<String> _inFlight = <String>{};

String _key(String deviceId, String command) => '$deviceId\u0000$command';

/// Claims [command] for [deviceId]. Returns false when an identical command is already outstanding, in
/// which case the caller must not send.
bool beginCommandSend(String deviceId, String command) => _inFlight.add(_key(deviceId, command));

/// Releases the claim taken by [beginCommandSend]. Safe to call when nothing is claimed.
void endCommandSend(String deviceId, String command) => _inFlight.remove(_key(deviceId, command));

/// Number of commands currently outstanding, for tests and diagnostics.
int get commandsInFlightCount => _inFlight.length;
