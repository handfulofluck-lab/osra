import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:familyshield_parent/l10n/app_localizations.dart';

/// The four P-09 Apps values the Arabic Language Bureau decided at 14:09 UAE
/// (#604, comment 7215542085). These keys are added ahead of their call sites,
/// so the only thing that can be asserted today is that each catalog carries the
/// approved wording verbatim.
void main() {
  final en = lookupAppLocalizations(const Locale('en'));
  final ar = lookupAppLocalizations(const Locale('ar'));

  test('appsFilterAllowed carries the count and the Bureau wording', () {
    expect(en.appsFilterAllowed('4'), 'Allowed (4)');
    expect(ar.appsFilterAllowed('4'), 'مسموح (4)');
  });

  test('appsLimitSheetTitle names the app', () {
    expect(en.appsLimitSheetTitle('TikTok'), 'Daily limit for TikTok');
    expect(ar.appsLimitSheetTitle('TikTok'), 'الحد اليومي لتطبيق TikTok');
  });

  test('appsNoLimit is the short clearing action', () {
    expect(en.appsNoLimit, 'No limit');
    expect(ar.appsNoLimit, 'بلا حد');
  });

  test('appsIphoneNoAppList is the short English the Bureau asked for', () {
    expect(en.appsIphoneNoAppList, "The iPhone doesn't send its app list yet.");
    expect(ar.appsIphoneNoAppList, 'لا يرسل هاتف آيفون قائمة التطبيقات بعد.');
    expect(en.appsIphoneNoAppList.contains('plumbing'), isFalse);
  });
}
