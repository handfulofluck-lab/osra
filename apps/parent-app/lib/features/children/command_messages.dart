import 'package:familyshield_parent/l10n/l10n.dart';

/// Issue #231: the parent-facing text for a refused command, in one place.
///
/// The reason vocabulary belongs to the agent (`background_location_missing`,
/// `lock_screen_unavailable`, `web_filter_not_set_up`, `unsupported_command`,
/// `invalid_payload`, …), so an unknown code falls back to the raw string rather than a vague
/// "failed" the parent cannot act on. `unlock`/`resume` have no reason: they are always acked
/// `ok`, with `detail.screen = dismissed|not_showing` (issue #233 review).
///
/// Two paths reach here and they must read the same:
/// - the **immediate** refusal, `POST /v1/devices/:id/command` → `{status:"failed", reason}`;
/// - the **device-side** refusal, which arrives later as an ack and is read from the command
///   row's `result.reason` ([DeviceCommand.refusalReason]).
String commandRefusalText(
  AppLocalizations l10n,
  String commandType,
  String deviceModel,
  Object? reason,
) {
  final type = l10n.commandType(commandType);
  return switch (reason) {
    'background_location_missing' => l10n.commandRefusedBackgroundLocation(type, deviceModel),
    'location_permission_missing' => l10n.commandRefusedLocationPermission(type, deviceModel),
    'lock_screen_unavailable' => l10n.commandRefusedLockScreen,
    'web_filter_not_set_up' => l10n.commandRefusedWebFilter,
    'unsupported_command' => l10n.commandRefusedUnsupportedCommand,
    // ADR-0034 decision 3: `not_supported` means the build or platform cannot do the feature at
    // all — not a fault, and not something the parent can fix by asking the child to open the app.
    // Today it reaches the parent only as a **device-side** ack (the iOS agent, #397), which child
    // detail and history already render here; the server-side up-front refusal arrives with
    // ADR-0034 PRs 2–3, and the map branch below is ready for it.
    'not_supported' => l10n.commandRefusedNotSupported(type, deviceModel),
    'invalid_payload' => l10n.commandRefusedInvalidPayload,
    _ => l10n.commandFailed('${reason ?? 'unknown'}'),
  };
}
