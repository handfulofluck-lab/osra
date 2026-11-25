import 'package:intl/intl.dart';

import '../../api/models.dart';
import '../../core/digits.dart';
import '../../core/ltr_isolate.dart';

bool isAccessRequestAlert(Alert alert) {
  if (alert.category != 'app_blocked') return false;
  final marker = alert.metadata['requestType'];
  if (marker != null) return marker == 'access';
  return alert.title == 'Access requested';
}

String appAlertPackageId(Alert alert) =>
    alert.metadata['packageId']?.toString().trim() ?? '';

typedef AppAlertIdentity = ({
  String name,
  InstalledApp? installed,
  bool packageFallback,
});

AppAlertIdentity resolveAppAlertIdentity(
  Alert alert,
  InstalledAppsReport? report,
) {
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
    name: packageId.isEmpty ? 'an app' : packageId,
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

String _childName(String? name) => firstStrongIsolate(
    (name == null || name.trim().isEmpty) ? 'Child' : name.trim());

String appAlertTitle({
  required Alert alert,
  required String localeName,
  required String? childName,
  required AppAlertIdentity identity,
}) {
  final app = isolateAppAlertName(identity);
  if (isAccessRequestAlert(alert)) {
    return localeName.startsWith('ar')
        ? 'طلب السماح باستخدام تطبيق'
        : '${_childName(childName)} asks to use $app';
  }
  return localeName.startsWith('ar')
      ? 'تم حظر تطبيق'
      : '$app was blocked on ${_childName(childName)}\'s phone';
}

String appAlertBody({
  required Alert alert,
  required String localeName,
  required String? childName,
  required AppAlertIdentity identity,
}) {
  final child = _childName(childName);
  final app = isolateAppAlertName(identity);
  if (isAccessRequestAlert(alert)) {
    return localeName.startsWith('ar')
        ? 'وصل طلب من $child للسماح باستخدام $app.'
        : '$child tapped "Request access" on the block screen.';
  }
  return localeName.startsWith('ar')
      ? 'مُنع فتح $app على هاتف $child.'
      : '$child tried to open it. Nothing for you to do.';
}

String accessApproveDisclosure({
  required String localeName,
  required AppAlertIdentity identity,
}) {
  final app = isolateAppAlertName(identity);
  return localeName.startsWith('ar')
      ? 'سيُسمح بتطبيق $app من الآن، مع استمرار تطبيق وقت النوم والساعات المدرسية والإيقاف المؤقت.'
      : '$app will be allowed from now on. Bedtime, school time and Pause still apply.';
}

String accessApproveError({
  required String localeName,
  required AppAlertIdentity identity,
}) {
  final app = isolateAppAlertName(identity);
  return localeName.startsWith('ar')
      ? 'تعذّر حفظ السماح. حاول مرة أخرى.'
      : 'Couldn\'t allow $app. Check your connection and try again.';
}

String accessReadOnlyLine({
  required String localeName,
  required String owner,
}) =>
    localeName.startsWith('ar')
        ? 'لا يمكن الموافقة على هذا الطلب أو رفضه إلا لمالك العائلة أو لوالد مشارك.'
        : 'Only ${firstStrongIsolate(owner)} can answer this request. Ask them to open OSRA.';

String accessResolvedLine({
  required String localeName,
  required String? resolution,
  required AppAlertIdentity identity,
  String? resolvedByName,
  DateTime? resolvedAt,
}) {
  if (resolution != 'allowed' && resolution != 'kept_blocked') {
    return localeName.startsWith('ar')
        ? 'تم التعامل مع هذا الطلب'
        : 'This request was handled';
  }
  if (localeName.startsWith('ar')) {
    return resolution == 'allowed'
        ? 'تمت الموافقة على هذا الطلب'
        : 'رُفض هذا الطلب';
  }
  final app = isolateAppAlertName(identity);
  final time = resolvedAt == null
      ? ''
      : ltrIsolate(normalizeDigits(
          DateFormat('HH:mm', 'en').format(resolvedAt.toLocal())));
  final suffix = time.isEmpty ? '' : ' · $time';
  final name = resolvedByName?.trim();
  if (name != null && name.isNotEmpty) {
    final actor = firstStrongIsolate(name);
    return resolution == 'allowed'
        ? '$actor allowed $app$suffix'
        : '$actor kept $app blocked$suffix';
  }
  return resolution == 'allowed'
      ? 'You allowed $app$suffix'
      : 'You kept $app blocked$suffix';
}

String accessResolvedSnack({
  required String localeName,
  required String resolution,
  required AppAlertIdentity identity,
  DateTime? resolvedAt,
}) {
  final app = isolateAppAlertName(identity);
  if (localeName.startsWith('ar')) {
    return resolution == 'allowed' ? 'تم السماح بتطبيق $app' : 'رُفض الطلب';
  }
  return accessResolvedLine(
    localeName: localeName,
    resolution: resolution,
    identity: identity,
    resolvedAt: resolvedAt,
  );
}

String accessAllowSemantics({
  required String localeName,
  required AppAlertIdentity identity,
}) =>
    localeName.startsWith('ar')
        ? 'السماح باستخدام ${isolateAppAlertName(identity)}'
        : 'Allow ${isolateAppAlertName(identity)}';

String accessDenySemantics({
  required String localeName,
  required AppAlertIdentity identity,
}) =>
    localeName.startsWith('ar')
        ? 'رفض طلب استخدام ${isolateAppAlertName(identity)}'
        : 'Keep ${isolateAppAlertName(identity)} blocked';
