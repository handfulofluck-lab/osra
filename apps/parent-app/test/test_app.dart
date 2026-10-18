import 'package:flutter/material.dart';

import 'package:familyshield_parent/l10n/l10n.dart';

/// A `MaterialApp` with the app's real localization delegates, so widget
/// tests exercise the same lookup path as `FamilyShieldApp`.
///
/// Pass `locale: const Locale('ar')` and `textDirection: TextDirection.rtl`
/// for the Arabic/RTL layout checks.
Widget localizedTestApp(
  Widget home, {
  Locale locale = const Locale('en'),
  ThemeData? theme,
  ThemeData? darkTheme,
  ThemeMode? themeMode,
  TextDirection? textDirection,
}) {
  return MaterialApp(
    locale: locale,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    theme: theme,
    darkTheme: darkTheme,
    themeMode: themeMode,
    home: textDirection == null
        ? home
        : Directionality(textDirection: textDirection, child: home),
  );
}
