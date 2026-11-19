import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:familyshield_parent/api/models.dart';
import 'package:familyshield_parent/core/ltr_isolate.dart';
import 'package:familyshield_parent/features/alerts/alerts_screen.dart';
import 'package:familyshield_parent/features/children/child_detail_screen.dart' show AlertTile;
import 'package:familyshield_parent/l10n/l10n.dart';
import 'package:familyshield_parent/providers/auth_provider.dart';
import 'package:familyshield_parent/push/local_notifier.dart';
import 'package:familyshield_parent/push/restart_alert_text.dart';

import 'fake_api_client.dart';
import 'test_app.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppLocalizations en;
  late AppLocalizations ar;

  setUpAll(() async {
    await initializeDateFormatting('en');
    await initializeDateFormatting('ar');
    en = await AppLocalizations.delegate.load(const Locale('en'));
    ar = await AppLocalizations.delegate.load(const Locale('ar'));
  });

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  Alert restartAlert({
    required DateTime bootedAtLocal,
    required int gapMinutes,
    String model = 'Galaxy Z Flip4',
    String severity = 'info',
    String? timeZone,
    int? utcOffsetMinutes,
  }) =>
      Alert(
        id: 'alert-restart-1',
        childId: 'child-1',
        deviceId: 'dev-1',
        severity: severity,
        category: 'device_restarted',
        title: 'Device restarted',
        body: 'SERVER FALLBACK',
        createdAt: bootedAtLocal.toUtc(),
        metadata: {
          'type': 'device_restarted',
          'bodyKey': 'alertBodyDeviceRestarted',
          'bodyParams': {
            'model': model,
            'bootedAt': bootedAtLocal.toUtc().toIso8601String(),
            'gapMinutes': gapMinutes,
            if (timeZone != null) 'timeZone': timeZone,
            if (utcOffsetMinutes != null) 'utcOffsetMinutes': utcOffsetMinutes,
          },
        },
      );

  group('RestartAlertText (#889 Bureau date, rounding, digits & LRI/PDI)', () {
    final now = DateTime(2026, 11, 19, 15, 0);

    test('today with minutes formats 24h HH:mm with isolated device & clock in EN and AR', () {
      final alert = restartAlert(bootedAtLocal: DateTime(2026, 11, 19, 14, 32), gapMinutes: 2);

      final enBody = RestartAlertText.tryFormat(alert, l10n: en, localeName: 'en', now: now);
      final arBody = RestartAlertText.tryFormat(alert, l10n: ar, localeName: 'ar', now: now);

      expect(enBody, '${ltrIsolate('Galaxy Z Flip4')} restarted at ${ltrIsolate('14:32')} and was back after 2 minutes.');
      expect(arBody, 'أُعيد تشغيل ${ltrIsolate('Galaxy Z Flip4')} الساعة ${ltrIsolate('14:32')}، وعاد إلى العمل بعد دقيقتين.');
    });

    test('gap under 1 minute says less than a minute and never 0 minutes', () {
      final alert = restartAlert(bootedAtLocal: DateTime(2026, 11, 19, 14, 32), gapMinutes: 0);

      final enBody = RestartAlertText.tryFormat(alert, l10n: en, localeName: 'en', now: now)!;
      final arBody = RestartAlertText.tryFormat(alert, l10n: ar, localeName: 'ar', now: now)!;

      expect(enBody, contains('in less than a minute.'));
      expect(enBody, isNot(contains('0 minute')));
      expect(arBody, contains('أقل من دقيقة'));
      expect(arBody, isNot(contains('0 ')));
    });

    test('yesterday with hours uses yesterday label and rounds 30m+ up from 120m threshold', () {
      final yesterdayBoot = DateTime(2026, 11, 18, 8, 58);

      final m119 = restartAlert(bootedAtLocal: yesterdayBoot, gapMinutes: 119);
      final m120 = restartAlert(bootedAtLocal: yesterdayBoot, gapMinutes: 120);
      final m149 = restartAlert(bootedAtLocal: yesterdayBoot, gapMinutes: 149);
      final m150 = restartAlert(bootedAtLocal: yesterdayBoot, gapMinutes: 150);
      final m600 = restartAlert(bootedAtLocal: yesterdayBoot, gapMinutes: 600, severity: 'warning');

      expect(RestartAlertText.tryFormat(m119, l10n: en, localeName: 'en', now: now), contains('after 119 minutes.'));
      expect(RestartAlertText.tryFormat(m120, l10n: en, localeName: 'en', now: now), contains('after about 2 hours.'));
      expect(RestartAlertText.tryFormat(m149, l10n: en, localeName: 'en', now: now), contains('after about 2 hours.'));
      expect(RestartAlertText.tryFormat(m150, l10n: en, localeName: 'en', now: now), contains('after about 3 hours.'));
      expect(
        RestartAlertText.tryFormat(m600, l10n: ar, localeName: 'ar', now: now),
        'أُعيد تشغيل ${ltrIsolate('Galaxy Z Flip4')} أمس الساعة ${ltrIsolate('08:58')}، وعاد إلى العمل بعد نحو 10 ساعات.',
      );
    });

    test('older date omits current year and includes different year, always Western 0-9', () {
      final sameYear = restartAlert(bootedAtLocal: DateTime(2026, 11, 16, 8, 58), gapMinutes: 180);
      final priorYear = restartAlert(bootedAtLocal: DateTime(2025, 11, 16, 8, 58), gapMinutes: 180);

      final enSame = RestartAlertText.tryFormat(sameYear, l10n: en, localeName: 'en', now: now)!;
      final enPrior = RestartAlertText.tryFormat(priorYear, l10n: en, localeName: 'en', now: now)!;
      final arSame = RestartAlertText.tryFormat(sameYear, l10n: ar, localeName: 'ar', now: now)!;
      final arPrior = RestartAlertText.tryFormat(priorYear, l10n: ar, localeName: 'ar', now: now)!;

      expect(enSame, contains('on 16 Nov at '));
      expect(enSame, isNot(contains('2026')));
      expect(enPrior, contains('on 16 Nov 2025 at '));
      expect(arSame, contains('يوم 16 نوفمبر الساعة '));
      expect(arSame, isNot(contains('2026')));
      expect(arPrior, contains('يوم 16 نوفمبر 2025 الساعة '));
      // No Eastern Arabic digits allowed (#762).
      expect(RegExp(r'[\u0660-\u0669\u06F0-\u06F9]').hasMatch(arSame), isFalse);
      expect(RegExp(r'[\u0660-\u0669\u06F0-\u06F9]').hasMatch(arPrior), isFalse);
    });

    test('VisibleAlert.from uses localized title and body for warning device_restarted and generic fallback when unparsable', () {
      final warningAlert = restartAlert(
        bootedAtLocal: DateTime(2026, 11, 19, 14, 32),
        gapMinutes: 40,
        severity: 'warning',
      );
      final visibleAr = VisibleAlert.from(warningAlert, l10n: ar, isEnglish: false, now: now);
      expect(visibleAr.title, ar.alertDeviceRestartedTitle);
      expect(visibleAr.body, contains('أُعيد تشغيل '));
      expect(visibleAr.body, isNot(contains('SERVER FALLBACK')));

      const brokenRestart = Alert(
        id: 'broken-1',
        childId: 'child-1',
        severity: 'warning',
        category: 'device_restarted',
        title: 'Device restarted',
        body: 'SERVER ENGLISH',
      );
      final fallbackAr = VisibleAlert.from(brokenRestart, l10n: ar, isEnglish: false, now: now);
      expect(fallbackAr.title, ar.alertDeviceRestartedTitle);
      expect(fallbackAr.body, ar.alertPushBodyGeneric);
      expect(fallbackAr.body, isNot(contains('SERVER ENGLISH')));

      // Empty model or un-keyed metadata must never synthesize English 'A phone' on Arabic UI (#889 / Antigravity).
      final emptyModel = restartAlert(
        bootedAtLocal: DateTime.utc(2026, 11, 19, 10, 32),
        gapMinutes: 40,
        model: '   ',
        severity: 'warning',
        timeZone: 'Asia/Dubai',
      );
      final unkeyed = Alert(
        id: 'legacy-867',
        childId: 'child-1',
        severity: 'warning',
        category: 'device_restarted',
        title: 'Device restarted',
        body: 'A phone restarted at 14:32 and was back after 40 minutes.',
        metadata: {
          'type': 'device_restarted',
          'bootedAt': '2026-11-19T10:32:00.000Z',
          'gapMinutes': 40,
        },
      );
      expect(RestartAlertText.tryParse(emptyModel), isNull);
      expect(RestartAlertText.tryParse(unkeyed), isNull);

      final emptyVisibleAr = VisibleAlert.from(emptyModel, l10n: ar, isEnglish: false, now: now);
      final unkeyedVisibleAr = VisibleAlert.from(unkeyed, l10n: ar, isEnglish: false, now: now);
      expect(emptyVisibleAr.body, ar.alertPushBodyGeneric);
      expect(emptyVisibleAr.body, isNot(contains('A phone')));
      expect(unkeyedVisibleAr.body, ar.alertPushBodyGeneric);
      expect(unkeyedVisibleAr.body, isNot(contains('A phone')));
    });

    test('family timezone governs clock and yesterday/today across midnight even when phone clock differs (#889)', () {
      // Codex scenario: Dubai family (UTC+4). Boot at 19:30 UTC (23:30 Dubai on 18 Nov),
      // viewed at 21:30 UTC (01:30 Dubai on 19 Nov). In UTC both instants share 18 Nov ("today at 19:30");
      // in Dubai the boot happened "yesterday at 23:30".
      final crossMidnightBoot = DateTime.utc(2026, 11, 18, 19, 30);
      final viewAt = DateTime.utc(2026, 11, 18, 21, 30);
      final alert = restartAlert(
        bootedAtLocal: crossMidnightBoot,
        gapMinutes: 40,
        severity: 'warning',
        timeZone: 'Asia/Dubai',
        utcOffsetMinutes: 240,
      );

      final formattedEn = RestartAlertText.tryFormat(alert, l10n: en, localeName: 'en', now: viewAt);
      final formattedAr = RestartAlertText.tryFormat(alert, l10n: ar, localeName: 'ar', now: viewAt);
      expect(
        formattedEn,
        '${ltrIsolate('Galaxy Z Flip4')} restarted yesterday at ${ltrIsolate('23:30')} and was back after 40 minutes.',
      );
      expect(
        formattedAr,
        'أُعيد تشغيل ${ltrIsolate('Galaxy Z Flip4')} أمس الساعة ${ltrIsolate('23:30')}، وعاد إلى العمل بعد 40 دقيقة.',
      );

      final visibleEn = VisibleAlert.from(alert, l10n: en, isEnglish: true, now: viewAt);
      final visibleAr = VisibleAlert.from(alert, l10n: ar, isEnglish: false, now: viewAt);
      expect(visibleEn.body, formattedEn);
      expect(visibleAr.body, formattedAr);

      // Valid IANA zone outside curated catalog spanning a DST clock change (Codex #930 review):
      // Europe/Vilnius ends summer time (+03:00 -> +02:00) at 2026-10-25T01:00Z.
      // Boot at 2026-10-24T21:15Z is 2026-10-25 00:15 (+03:00); read at 2026-10-25T21:30Z is 2026-10-25 23:30 (+02:00).
      // Applying the boot's +03:00 offset to `now` would push the read to 2026-10-26 00:30 and wrongly say "yesterday".
      final dstCrossZone = restartAlert(
        bootedAtLocal: DateTime.utc(2026, 10, 24, 21, 15),
        gapMinutes: 35,
        severity: 'warning',
        timeZone: 'Europe/Vilnius',
        utcOffsetMinutes: 180,
      );
      final vilniusRead = DateTime.utc(2026, 10, 25, 21, 30);
      expect(
        RestartAlertText.tryFormat(dstCrossZone, l10n: en, localeName: 'en', now: vilniusRead),
        '${ltrIsolate('Galaxy Z Flip4')} restarted at ${ltrIsolate('00:15')} and was back after 35 minutes.',
      );
      expect(
        RestartAlertText.tryFormat(dstCrossZone, l10n: ar, localeName: 'ar', now: vilniusRead),
        'أُعيد تشغيل ${ltrIsolate('Galaxy Z Flip4')} الساعة ${ltrIsolate('00:15')}، وعاد إلى العمل بعد 35 دقيقة.',
      );

      // Unknown zone name still falls back cleanly to server-provided utcOffsetMinutes.
      final offsetFallback = restartAlert(
        bootedAtLocal: crossMidnightBoot,
        gapMinutes: 35,
        severity: 'warning',
        timeZone: 'Custom/Plus0545',
        utcOffsetMinutes: 345,
      );
      expect(
        RestartAlertText.tryFormat(offsetFallback, l10n: en, localeName: 'en', now: viewAt),
        '${ltrIsolate('Galaxy Z Flip4')} restarted at ${ltrIsolate('01:15')} and was back after 35 minutes.',
      );
    });
  });

  group('AlertsScreen device_restarted UI (#889, 320 px / 200 %)', () {
    Future<void> pumpAlerts(
      WidgetTester tester,
      Locale locale,
      List<Alert> items, {
      DateTime Function()? nowProvider,
    }) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1.0;
      tester.platformDispatcher.textScaleFactorTestValue = 2.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        tester.platformDispatcher.clearTextScaleFactorTestValue();
      });

      final api = FakeApiClient({
        ...standardRoutes(),
        'GET /v1/alerts': (_) => {
              'items': [
                for (final a in items)
                  {
                    'id': a.id,
                    'childId': a.childId,
                    'deviceId': a.deviceId,
                    'severity': a.severity,
                    'category': a.category,
                    'title': a.title,
                    'body': a.body,
                    'metadata': a.metadata,
                    'createdAt': a.createdAt?.toIso8601String(),
                    'acknowledged': a.acknowledged,
                  }
              ],
              'meta': {'total': items.length, 'page': 1, 'limit': 20},
            },
      });

      await tester.pumpWidget(ProviderScope(
        overrides: [apiClientProvider.overrideWithValue(api)],
        child: localizedTestApp(
          AlertsScreen(nowProvider: nowProvider),
          locale: locale,
          textDirection: locale.languageCode == 'ar' ? TextDirection.rtl : TextDirection.ltr,
        ),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('Alerts list row shows localized title and category chip, never raw device_restarted', (tester) async {
      final item = restartAlert(bootedAtLocal: DateTime.now().subtract(const Duration(minutes: 5)), gapMinutes: 2);
      await pumpAlerts(tester, const Locale('ar'), [item]);

      expect(find.byType(AlertTile), findsOneWidget);
      expect(find.text(ar.alertDeviceRestartedTitle), findsOneWidget);
      expect(find.textContaining(ar.alertCategoryDeviceRestarted), findsOneWidget);
      expect(find.textContaining('device_restarted'), findsNothing);
      expect(tester.takeException(), isNull);

      await tester.tap(find.byType(AlertTile));
      await tester.pumpAndSettle();

      expect(find.textContaining('وعاد إلى العمل بعد دقيقتين'), findsOneWidget);
      expect(find.text('SERVER FALLBACK'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('English Alerts list row and detail dialog show localized title, chip, and body at 320 / 200 %', (tester) async {
      final item = restartAlert(bootedAtLocal: DateTime.now().subtract(const Duration(minutes: 5)), gapMinutes: 150, severity: 'warning');
      await pumpAlerts(tester, const Locale('en'), [item]);

      expect(find.byType(AlertTile), findsOneWidget);
      expect(find.text(en.alertDeviceRestartedTitle), findsOneWidget);
      expect(find.textContaining('${en.alertCategoryDeviceRestarted} ·'), findsOneWidget);
      expect(find.textContaining('device_restarted'), findsNothing);
      expect(tester.takeException(), isNull);

      await tester.tap(find.byType(AlertTile));
      await tester.pumpAndSettle();

      expect(find.textContaining('and was back after about 3 hours.'), findsOneWidget);
      expect(find.text('SERVER FALLBACK'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('AlertsScreen dialog renders family timezone across midnight in EN and AR (#889)', (tester) async {
      final crossMidnightAlert = restartAlert(
        bootedAtLocal: DateTime.utc(2026, 11, 18, 19, 30),
        gapMinutes: 40,
        severity: 'warning',
        timeZone: 'Asia/Dubai',
        utcOffsetMinutes: 240,
      );
      DateTime fixedNow() => DateTime.utc(2026, 11, 18, 21, 30);

      await pumpAlerts(tester, const Locale('en'), [crossMidnightAlert], nowProvider: fixedNow);
      await tester.tap(find.byType(AlertTile));
      await tester.pumpAndSettle();
      expect(
        find.text('${ltrIsolate('Galaxy Z Flip4')} restarted yesterday at ${ltrIsolate('23:30')} and was back after 40 minutes.'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);

      await tester.tap(find.text(en.close));
      await tester.pumpAndSettle();

      await pumpAlerts(tester, const Locale('ar'), [crossMidnightAlert], nowProvider: fixedNow);
      await tester.tap(find.byType(AlertTile));
      await tester.pumpAndSettle();
      expect(
        find.text('أُعيد تشغيل ${ltrIsolate('Galaxy Z Flip4')} أمس الساعة ${ltrIsolate('23:30')}، وعاد إلى العمل بعد 40 دقيقة.'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('AlertsScreen Arabic dialog omits body on unkeyed legacy restart, never English body or push prompt (#889)', (tester) async {
      final legacyUnkeyed = Alert(
        id: 'legacy-restart-1',
        childId: 'child-1',
        severity: 'warning',
        category: 'device_restarted',
        title: 'Device restarted',
        body: 'Pixel 7a restarted at 14:32 and was back after 40 minutes.',
        createdAt: DateTime.utc(2026, 11, 19, 10, 32),
        metadata: const {
          'type': 'device_restarted',
          'bootedAt': '2026-11-19T10:32:00.000Z',
          'gapMinutes': 40,
        },
      );

      await pumpAlerts(tester, const Locale('ar'), [legacyUnkeyed]);
      await tester.tap(find.byType(AlertTile));
      await tester.pumpAndSettle();

      expect(find.text(ar.alertDeviceRestartedTitle), findsNWidgets(2));
      expect(find.text(ar.alertPushBodyGeneric), findsNothing);
      expect(find.textContaining('Pixel 7a restarted'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
}
