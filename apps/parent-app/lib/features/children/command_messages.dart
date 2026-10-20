import 'package:familyshield_parent/l10n/l10n.dart';

/// Issue #231: the parent-facing text for a refused command, in one place.
///
/// The reason vocabulary belongs to the agent (`background_location_missing`,
/// `lock_screen_unavailable`, `unlock_screen_unavailable`, `web_filter_not_set_up`,
/// `unsupported_command`, `invalid_payload`, …), so an unknown code falls back to the
/// raw string rather than a vague "failed" the parent cannot act on.
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
    'unlock_screen_unavailable' => l10n.commandRefusedUnlockScreen,
    'web_filter_not_set_up' => l10n.commandRefusedWebFilter,
    'unsupported_command' => l10n.commandRefusedUnsupportedCommand,
    'invalid_payload' => l10n.commandRefusedInvalidPayload,
    _ => l10n.commandFailed('${reason ?? 'unknown'}'),
  };
}
