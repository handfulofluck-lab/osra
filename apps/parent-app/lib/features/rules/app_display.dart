import 'package:flutter/material.dart';

import '../../api/models.dart';
import 'app_picker.dart' show AppIconBadge;
import '../../l10n/l10n.dart';

/// The name a parent reads for a package id, and the avatar beside it.
///
/// Claude's answer on #872 (05:16Z) settled where a name comes from: the child's latest installed-apps
/// report, resolved at display time. `alwaysAllowedApps` stays a `string[]` on the server, so the id is the
/// key and the name is looked up; no schema change and no cache that would drift from the report.
///
/// The fallback is the Bureaus' line, not the id: a rule saved before names were stored carries the id in
/// `appName`, and a parent should never read `com.example.app` on their own screen. A "?" avatar marks the
/// row the same way, so the chip, the rule row and the routine chip share one look.
String appDisplayName(
  BuildContext context,
  Map<String, InstalledApp> apps,
  String packageId, {
  String? savedName,
}) {
  final reported = apps[packageId];
  if (reported != null) return reported.label;
  final name = (savedName ?? '').trim();
  // A saved name that is the id is not a name; both paths fall through to the Bureaus' line.
  if (name.isNotEmpty && name != packageId) return name;
  return context.l10n.appNoLongerInstalled;
}

/// The avatar for a chip or row: the app's own icon when the device reported it, a "?" when it did not.
Widget appDisplayAvatar(Map<String, InstalledApp> apps, String packageId, {double size = 20}) {
  final app = apps[packageId];
  return AppIconBadge(
    app: app ?? InstalledApp(packageId: packageId, label: '?'),
    size: size,
  );
}
