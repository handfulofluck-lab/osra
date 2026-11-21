import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:familyshield_parent/api/models.dart';
import 'package:familyshield_parent/features/rules/app_picker.dart';
import 'package:familyshield_parent/l10n/app_localizations_ar.dart';
import 'package:familyshield_parent/l10n/app_localizations_en.dart';
import 'package:familyshield_parent/l10n/l10n.dart';
import 'package:familyshield_parent/theme/app_theme.dart';

/// #929, the Arabic Language Bureau's three items — pinned as **literals**, not as `l10n.x`, because a
/// row that compares the screen to the getter feeding it passes whatever the ARB says (the #429 lesson).
/// The Arabic below is copied from the Bureau's issued lines; `flutter gen-l10n` output is checked against
/// it here rather than trusted.
void main() {
  test('the Arabic "first N apps" notice uses the right plural', () {
    final ar = AppLocalizationsAr();
    // 500 is the Android cap (InstalledAppsPolicy.MAX_APPS): above 100 the singular word is correct.
    expect(ar.installedAppsTruncated(500), 'عرض أول 500 تطبيق');
    expect(ar.installedAppsTruncated(3), 'عرض أول 3 تطبيقات');
    expect(ar.installedAppsTruncated(11), 'عرض أول 11 تطبيقًا');
    // English is untouched by this change.
    expect(AppLocalizationsEn().installedAppsTruncated(500), 'Showing the first 500 apps.');
  });

  test('the "Allow" label is the standard Arabic word', () {
    final ar = AppLocalizationsAr();
    expect(ar.allowAction, 'السماح');
    expect(ar.appActionAllow, 'السماح');
  });

  testWidgets('the unknown-app badge is «؟» in Arabic and "?" in English', (tester) async {
    Future<void> pump(Locale locale, TextDirection direction) async {
      await tester.pumpWidget(MaterialApp(
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: AppTheme.light,
        home: Directionality(
          textDirection: direction,
          child: const Center(child: AppIconBadge(app: InstalledApp(packageId: 'com.example.gone', label: ''))),
        ),
      ));
      await tester.pumpAndSettle();
    }

    await pump(const Locale('ar'), TextDirection.rtl);
    expect(find.text('؟'), findsOneWidget, reason: 'Arabic uses the mirrored question mark');
    expect(find.text('?'), findsNothing);

    await pump(const Locale('en'), TextDirection.ltr);
    expect(find.text('?'), findsOneWidget);
    expect(find.text('؟'), findsNothing);
  });
}
