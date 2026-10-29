import 'package:dio/dio.dart';
import 'package:familyshield_parent/l10n/l10n.dart';

import '../../api/permission_errors.dart';

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
/// `reason`. The body's `error` field is a different vocabulary from the agent's reason.
///
/// The keys are the shapes the routes actually send, checked against `services/api/src`:
/// - `403 { error: "permission_required", permission }` from `requirePermission(...)`, detected by
///   [ReadPermissionRequired.from] so the shape is decided in one place (#434 review);
/// - `429` from `@fastify/rate-limit`, whose body is Fastify's own (`error: "Too Many Requests"`), so
///   the status code is the key — the strings `rate_limited`/`too_many_requests` never arrive here;
/// - otherwise a **reason** the agent would have used, rendered by [commandRefusalText] so one cause
///   keeps one sentence whichever path refused;
/// - and anything else **verbatim**, because hiding an unknown code behind a generic "failed" is the
///   same mistake as reporting a refused command as queued — it removes the only clue anyone has.
String commandErrorText(
  AppLocalizations l10n,
  String commandType,
  String deviceModel,
  Object error,
) {
  final type = l10n.commandType(commandType);
  if (error is DioException) {
    // The permission is deliberately not named: a guardian does not know the invite vocabulary, and
    // `devices` in an Arabic sentence reads as a bug (`readPermissionRequired`'s reasoning).
    if (ReadPermissionRequired.from(error) != null) return l10n.commandErrorForbidden(type, deviceModel);
    if (error.response?.statusCode == 429) return l10n.commandErrorRateLimited(type, deviceModel);
  }
  final body = error is DioException ? error.response?.data : null;
  final code = body is Map ? (body['error'] ?? (error as DioException).message) : (error is DioException ? error.message : error);
  final raw = '${code ?? 'unknown'}';
  final mapped = commandRefusalText(l10n, commandType, deviceModel, code);
  if (mapped != l10n.commandFailed(raw)) return mapped;
  return l10n.commandFailed(raw);
}
