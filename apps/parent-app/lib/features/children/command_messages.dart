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

/// Issue #434: the text for a command refused by an **HTTP error** rather than by a `200` with a
/// `reason`. The body's `error` field is a different vocabulary from the agent's reason: it can carry
/// a reason-shaped code (`not_supported` appears on a refused device ack as well), an authorisation
/// refusal, or a rate limit.
///
/// The order matters, and so does the fallback:
/// 1. a reason the agent would have used is rendered by [commandRefusalText] — one command never has
///    two sentences for the same cause;
/// 2. `forbidden` / `not_owner` become "you do not have permission", which a parent can act on;
/// 3. `rate_limited` / `too_many_requests` say to try again shortly, because "429" is not an action;
/// 4. anything else stays **verbatim**. Hiding an unknown code behind a generic "failed" is the same
///    mistake as reporting a refused command as queued: it removes the one clue a parent or we have.
String commandErrorText(
  AppLocalizations l10n,
  String commandType,
  String deviceModel,
  Object? error,
) {
  final code = error is String ? error : (error == null ? '' : '$error');
  final type = l10n.commandType(commandType);
  final mapped = commandRefusalText(l10n, commandType, deviceModel, code);
  // commandRefusalText falls back to `commandFailed(code)`; if it produced that, nothing knew the code.
  if (mapped != l10n.commandFailed(code)) return mapped;
  return switch (code) {
    'forbidden' || 'not_owner' || 'insufficient_permission' =>
      l10n.commandErrorForbidden(type, deviceModel),
    'rate_limited' || 'too_many_requests' => l10n.commandErrorRateLimited(type, deviceModel),
    _ => l10n.commandFailed(code),
  };
}
