import 'package:intl/intl.dart';

import '../../api/models.dart';
import '../../core/digits.dart';
import '../../core/ltr_isolate.dart';
import '../../l10n/app_localizations.dart';

bool isAccessRequestAlert(Alert alert) {
  if (alert.category != 'app_blocked') return false;
  final marker = alert.metadata['requestType'];
  if (marker != null) return marker == 'access';
  return alert.title == 'Access requested';
}

bool isParentDecisionAlert(Alert alert) =>
    isAccessRequestAlert(alert) || alert.requestedScreenTimeMinutes != null;

String appAlertPackageId(Alert alert) =>
    alert.metadata['packageId']?.toString().trim() ?? '';

typedef AppAlertIdentity = ({
  String name,
  InstalledApp? installed,
  bool packageFallback,
});

AppAlertIdentity resolveAppAlertIdentity(
  Alert alert,
  InstalledAppsReport? report, {
  required String fallbackName,
}) {
  final packageId = appAlertPackageId(alert);
  final installed =
      report?.apps.where((app) => app.packageId == packageId).firstOrNull;
  final installedName = installed?.label.trim() ?? '';
  if (installedName.isNotEmpty && installedName != packageId) {
    return (name: installedName, installed: installed, packageFallback: false);
  }
  final metadataName = alert.metadata['appName']?.toString().trim() ?? '';
  if (metadataName.isNotEmpty && metadataName != packageId) {
    return (name: metadataName, installed: installed, packageFallback: false);
  }
  return (
    name: packageId.isEmpty ? fallbackName : packageId,
    installed: installed,
    packageFallback: packageId.isNotEmpty,
  );
}

InstalledAppsReport? alertInstalledAppsReport(
  List<DeviceApps>? devices,
  String? deviceId,
) {
  if (devices == null) return null;
  final matching =
      devices.where((item) => item.deviceId == deviceId).firstOrNull;
  if (matching != null) return matching.report;
  var merged = const InstalledAppsReport();
  for (final device in devices) {
    merged = merged.merge(device.report);
  }
  return merged;
}

String isolateAppAlertName(AppAlertIdentity identity) =>
    identity.packageFallback
        ? ltrIsolate(identity.name)
        : firstStrongIsolate(identity.name);

String _childName(String? name, AppLocalizations l10n) {
  final trimmed = name?.trim();
  return firstStrongIsolate(
    trimmed == null || trimmed.isEmpty ? l10n.childFallback : trimmed,
  );
}

String appAlertTitle({
  required Alert alert,
  required AppLocalizations l10n,
  required String? childName,
  required AppAlertIdentity identity,
}) {
  final child = _childName(childName, l10n);
  final minutes = alert.requestedScreenTimeMinutes;
  if (minutes != null) {
    return l10n.timeRequestTitle(
        child, ltrIsolate(normalizeDigits('$minutes')));
  }
  final app = isolateAppAlertName(identity);
  return isAccessRequestAlert(alert)
      ? l10n.accessRequestTitle(child, app)
      : l10n.accessRequestBlockedTitle(app, child);
}

String appAlertBody({
  required Alert alert,
  required AppLocalizations l10n,
  required String? childName,
}) {
  if (alert.requestedScreenTimeMinutes != null)
    return l10n.extraScreenTimeToday;
  final child = _childName(childName, l10n);
  return isAccessRequestAlert(alert)
      ? l10n.accessRequestBody(child)
      : l10n.accessRequestBlockedBody(child);
}

String accessApproveDisclosure({
  required AppLocalizations l10n,
  required AppAlertIdentity identity,
}) =>
    l10n.accessRequestDisclosure(isolateAppAlertName(identity));

String accessApproveError({
  required AppLocalizations l10n,
  required AppAlertIdentity identity,
}) =>
    l10n.accessRequestAllowFailed(isolateAppAlertName(identity));

String accessReadOnlyLine({
  required AppLocalizations l10n,
  required String owner,
}) =>
    l10n.accessRequestReadOnly(firstStrongIsolate(owner));

String _timeSuffix(DateTime? resolvedAt) {
  if (resolvedAt == null) return '';
  final time = DateFormat('HH:mm', 'en').format(resolvedAt.toLocal());
  return ' · ${ltrIsolate(normalizeDigits(time))}';
}

String accessResolvedLine({
  required AppLocalizations l10n,
  required String? resolution,
  required AppAlertIdentity identity,
  String? resolvedByName,
  DateTime? resolvedAt,
}) {
  if (resolution != 'allowed' && resolution != 'kept_blocked') {
    return l10n.accessRequestHandled;
  }
  final app = isolateAppAlertName(identity);
  final suffix = _timeSuffix(resolvedAt);
  final name = resolvedByName?.trim();
  if (name != null && name.isNotEmpty) {
    final actor = firstStrongIsolate(name);
    return resolution == 'allowed'
        ? l10n.accessRequestAllowedBy(actor, app, suffix)
        : l10n.accessRequestKeptBlockedBy(actor, app, suffix);
  }
  return resolution == 'allowed'
      ? l10n.accessRequestAllowedByYou(app, suffix)
      : l10n.accessRequestKeptBlockedByYou(app, suffix);
}

String accessResolvedSnack({
  required AppLocalizations l10n,
  required String resolution,
  required AppAlertIdentity identity,
  DateTime? resolvedAt,
}) {
  final app = isolateAppAlertName(identity);
  final suffix = _timeSuffix(resolvedAt);
  return switch (resolution) {
    'allowed' => l10n.accessRequestAllowedSnack(app, suffix),
    'kept_blocked' => l10n.accessRequestKeptBlockedSnack(app, suffix),
    _ => l10n.accessRequestHandled,
  };
}

String accessAllowSemantics({
  required AppLocalizations l10n,
  required AppAlertIdentity identity,
}) =>
    l10n.accessRequestAllowLabel(isolateAppAlertName(identity));

String accessDenySemantics({
  required AppLocalizations l10n,
  required AppAlertIdentity identity,
}) =>
    l10n.accessRequestKeepBlockedLabel(isolateAppAlertName(identity));
