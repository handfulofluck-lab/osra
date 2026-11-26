import 'package:familyshield_parent/api/models.dart';
import 'package:familyshield_parent/core/ltr_isolate.dart';
import 'package:familyshield_parent/features/alerts/alert_detail_screen.dart';
import 'package:familyshield_parent/l10n/app_localizations_en.dart';
import 'package:familyshield_parent/l10n/app_localizations_ar.dart';
import 'package:familyshield_parent/l10n/l10n.dart';
import 'package:familyshield_parent/push/local_notifier.dart';
import 'package:flutter_test/flutter_test.dart';

Alert alert({
  required String type,
  required String bodyKey,
  required Map<String, dynamic> bodyParams,
  Map<String, dynamic> extra = const {},
  String body = 'SERVER ENGLISH',
}) =>
    Alert.fromJson({
      'id': 'alert-$type',
      'childId': 'child-1',
      'severity': type == 'setup_complete' ? 'info' : 'warning',
      'category': 'tamper',
      'title': 'Server title',
      'body': body,
      'metadata': {
        'type': type,
        'bodyKey': bodyKey,
        'bodyParams': bodyParams,
        ...extra,
      },
      'createdAt': '2026-11-26T01:00:00.000Z',
      'acknowledged': false,
    });

void main() {
  final en = AppLocalizationsEn();
  final ar = AppLocalizationsAr();

  test(
      'setup completion has localized title and body, with generic lock-screen body',
      () {
    final row = alert(
        type: 'setup_complete',
        bodyKey: 'alertBodySetupCompleted',
        bodyParams: {'childName': 'Child One'});
    expect(formatGeneralAlertBody(row, l10n: en, localeName: 'en'),
        "${firstStrongIsolate('Child One')}'s phone is protected.");
    expect(formatGeneralAlertBody(row, l10n: ar, localeName: 'ar'),
        'هاتف ${firstStrongIsolate('Child One')} محمي.');
    expect(
        ar.alertTitleFor('tamper', row.title,
            isEnglish: false, tamperType: 'setup_complete'),
        'الهاتف محمي');
    final visible = VisibleAlert.from(row, l10n: ar, isEnglish: false);
    expect(visible.title, 'الهاتف محمي');
    expect(visible.body, ar.alertPushBodyGeneric);
  });

  test(
      'setup timeout localizes the grant list instead of inserting English steps',
      () {
    final row = alert(
      type: 'setup_incomplete',
      bodyKey: 'alertBodySetupIncomplete',
      bodyParams: {
        'childName': 'Child One',
        'count': 2,
        'steps': 'accessibility, overlay'
      },
      extra: {
        'missing': ['accessibility', 'overlay']
      },
    );
    expect(
      formatGeneralAlertBody(row, l10n: en, localeName: 'en'),
      "${firstStrongIsolate('Child One')}'s phone still has 2 setup steps left after 30 minutes: Accessibility service, Display over other apps.",
    );
    expect(
      formatGeneralAlertBody(row, l10n: ar, localeName: 'ar'),
      'مرّت 30 دقيقة، وتبقى خطوتان في إعداد هاتف ${firstStrongIsolate('Child One')}: خدمة إمكانية الوصول، العرض فوق التطبيقات الأخرى',
    );
    expect(
        ar.alertTitleFor('tamper', row.title,
            isEnglish: false, tamperType: 'setup_incomplete'),
        'إعداد الهاتف يحتاج إلى متابعة');
  });

  test('data-clear is named in the app and on the lock screen', () {
    final row = alert(
        type: 'agent_data_cleared',
        bodyKey: 'alertBodyDataCleared',
        bodyParams: {'model': 'Pixel 7a'});
    expect(
      formatGeneralAlertBody(row, l10n: en, localeName: 'en'),
      'OSRA was reinstalled on ${ltrIsolate('Pixel 7a')}. Its protection was off until it was paired again.',
    );
    expect(
      formatGeneralAlertBody(row, l10n: ar, localeName: 'ar'),
      'أُعيد تثبيت تطبيق أسرة للأطفال على ${ltrIsolate('Pixel 7a')}، وكانت الحماية متوقفة إلى أن أُعيد الإقران.',
    );
    expect(VisibleAlert.from(row, l10n: ar, isEnglish: false).title,
        'مُسحت بيانات تطبيق أسرة للأطفال على أحد الهواتف');
  });

  test(
      'malformed required params fall back without a placeholder or Arabic server-English leak',
      () {
    final row = alert(
        type: 'setup_complete',
        bodyKey: 'alertBodySetupCompleted',
        bodyParams: const {});
    expect(formatGeneralAlertBody(row, l10n: en, localeName: 'en'),
        'SERVER ENGLISH');
    expect(formatGeneralAlertBody(row, l10n: ar, localeName: 'ar'), '');
  });

  test(
      'an existing Arabic alert with no recognized body key keeps its stored body',
      () {
    final row = alert(
        type: 'legacy',
        bodyKey: 'legacy_alert',
        bodyParams: const {},
        body: 'نص التنبيه المحفوظ');
    expect(formatGeneralAlertBody(row, l10n: ar, localeName: 'ar'),
        'نص التنبيه المحفوظ');
  });

  test('an unknown setup step count uses generic localized incomplete copy',
      () {
    final row = alert(
      type: 'setup_incomplete',
      bodyKey: 'alertBodySetupIncomplete',
      bodyParams: {'childName': 'Child One', 'count': 0, 'steps': ''},
      extra: {'missing': <String>[]},
    );
    expect(
      formatGeneralAlertBody(row, l10n: en, localeName: 'en'),
      "${firstStrongIsolate('Child One')}'s phone setup is still incomplete after 30 minutes.",
    );
    expect(
      formatGeneralAlertBody(row, l10n: ar, localeName: 'ar'),
      'مرّت 30 دقيقة، وإعداد هاتف ${firstStrongIsolate('Child One')} ما زال غير مكتمل.',
    );
  });

  test(
      'non-finite, non-integral and wrongly typed setup parameters never reach localization',
      () {
    for (final count in [double.nan, double.infinity, -1.0, 1.5, '2']) {
      final row = alert(
        type: 'setup_incomplete',
        bodyKey: 'alertBodySetupIncomplete',
        bodyParams: {'childName': 'Child One', 'count': count},
        extra: {
          'missing': ['accessibility']
        },
      );
      expect(
        formatGeneralAlertBody(row, l10n: en, localeName: 'en'),
        "${firstStrongIsolate('Child One')}'s phone setup is still incomplete after 30 minutes.",
        reason: 'count $count',
      );
    }
    final badGrants = alert(
      type: 'setup_incomplete',
      bodyKey: 'alertBodySetupIncomplete',
      bodyParams: {'childName': 'Child One', 'count': 2},
      extra: {
        'missing': ['accessibility', 42]
      },
    );
    expect(
      formatGeneralAlertBody(badGrants, l10n: en, localeName: 'en'),
      "${firstStrongIsolate('Child One')}'s phone setup is still incomplete after 30 minutes.",
    );
    final badName = alert(
        type: 'setup_complete',
        bodyKey: 'alertBodySetupCompleted',
        bodyParams: {'childName': 42});
    expect(formatGeneralAlertBody(badName, l10n: ar, localeName: 'ar'), '');
    final badModel = alert(
        type: 'agent_data_cleared',
        bodyKey: 'alertBodyDataCleared',
        bodyParams: {
          'model': {'bad': true}
        });
    expect(formatGeneralAlertBody(badModel, l10n: ar, localeName: 'ar'), '');
  });
}
