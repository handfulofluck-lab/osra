import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:familyshield_parent/core/date_formatting.dart';
import 'package:familyshield_parent/features/alerts/alerts_screen.dart';
import 'package:familyshield_parent/features/children/child_detail_screen.dart'
    show AlertTile;
import 'package:familyshield_parent/l10n/l10n.dart';
import 'package:familyshield_parent/providers/auth_provider.dart';

import 'fake_api_client.dart';
import 'test_app.dart';

/// UI/UX Bureau U45 (7043461726 / 7043472688): alert detail dialog timestamps use
/// the #889 relative keys (`alertAtTime`, `alertYesterdayAtTime`, `alertOnDateAtTime`)
/// in 24-hour `HH:mm` without seconds (Western digits + LRI/PDI), and drop the `Severity` row.
///
/// Mutants (AGENTS.md §3):
/// - M1: Restore `DateFormat.yMMMd(...).add_Hms().format(...)` in `AlertsScreen._showDetail`:
///       both `formatAlertDetailTime` / widget time assertions (`no seconds`, `#889 key`) fail RED.
/// - M2: Restore `'${l10n.severityLabel(l10n.severityName(alert.severity))}'` in `_showDetail`:
///       `find.textContaining('Severity')` and `find.textContaining('الخطورة')` fail RED.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final arabicIndicDigits = RegExp(r'[\u0660-\u0669\u06F0-\u06F9]');
  final secondsRe = RegExp(r'\d{2}:\d{2}:\d{2}');

  setUpAll(() async {
    await configureDateFormatting();
  });

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  group('formatAlertDetailTime unit tests (U45 / #889 keys)', () {
    late AppLocalizations en;
    late AppLocalizations ar;
    final refNow = DateTime(2026, 11, 20, 18, 30);

    setUpAll(() async {
      en = await AppLocalizations.delegate.load(const Locale('en'));
      ar = await AppLocalizations.delegate.load(const Locale('ar'));
    });

    test('formats same day, yesterday, same-year older, and prior-year in EN without seconds', () {
      final today = formatAlertDetailTime(
        DateTime(2026, 11, 20, 9, 5, 42),
        l10n: en,
        localeName: 'en',
        now: refNow,
      );
      final yesterday = formatAlertDetailTime(
        DateTime(2026, 11, 19, 23, 45, 19),
        l10n: en,
        localeName: 'en',
        now: refNow,
      );
      final olderSameYear = formatAlertDetailTime(
        DateTime(2026, 11, 14, 16, 8, 43),
        l10n: en,
        localeName: 'en',
        now: refNow,
      );
      final priorYear = formatAlertDetailTime(
        DateTime(2025, 12, 31, 7, 30, 59),
        l10n: en,
        localeName: 'en',
        now: refNow,
      );

      expect(today, 'at \u{2066}09:05\u{2069}');
      expect(yesterday, 'yesterday at \u{2066}23:45\u{2069}');
      expect(olderSameYear, 'on 14 Nov at \u{2066}16:08\u{2069}');
      expect(priorYear, 'on 31 Dec 2025 at \u{2066}07:30\u{2069}');

      for (final s in [today, yesterday, olderSameYear, priorYear]) {
        expect(secondsRe.hasMatch(s), isFalse, reason: s);
      }
    });

    test('formats same day, yesterday, same-year older, and prior-year in AR with Western digits & LRI/PDI', () {
      final today = formatAlertDetailTime(
        DateTime(2026, 11, 20, 9, 5, 42),
        l10n: ar,
        localeName: 'ar',
        now: refNow,
      );
      final yesterday = formatAlertDetailTime(
        DateTime(2026, 11, 19, 23, 45, 19),
        l10n: ar,
        localeName: 'ar',
        now: refNow,
      );
      final olderSameYear = formatAlertDetailTime(
        DateTime(2026, 11, 14, 16, 8, 43),
        l10n: ar,
        localeName: 'ar',
        now: refNow,
      );
      final priorYear = formatAlertDetailTime(
        DateTime(2025, 12, 31, 7, 30, 59),
        l10n: ar,
        localeName: 'ar',
        now: refNow,
      );

      expect(today, 'الساعة \u{2066}09:05\u{2069}');
      expect(yesterday, 'أمس الساعة \u{2066}23:45\u{2069}');
      expect(olderSameYear, 'يوم 14 نوفمبر الساعة \u{2066}16:08\u{2069}');
      expect(priorYear, 'يوم 31 ديسمبر 2025 الساعة \u{2066}07:30\u{2069}');

      for (final s in [today, yesterday, olderSameYear, priorYear]) {
        expect(secondsRe.hasMatch(s), isFalse, reason: s);
        expect(arabicIndicDigits.hasMatch(s), isFalse, reason: s);
      }
    });
  });

  group('AlertsScreen U45 dialog layout at 320x568 / 200%', () {
    final fixedNow = DateTime(2026, 11, 20, 18, 30);

    Future<void> pumpAlert(
      WidgetTester tester, {
      required Locale locale,
      required DateTime createdAt,
    }) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1.0;
      tester.platformDispatcher.textScaleFactorTestValue = 2.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        tester.platformDispatcher.clearTextScaleFactorTestValue();
      });

      final routes = standardRoutes();
      routes['GET /v1/family/me'] = (_) => familyMeTwoChildren(alexName: 'Sam');
      routes['GET /v1/alerts'] = (_) => {
            'items': [
              {
                'id': 'alert-u45-1',
                'childId': 'child-1',
                'deviceId': 'dev-1',
                'severity': 'warning',
                'category': 'tamper',
                'title': 'Protection paused',
                'body': 'Protection paused on device.',
                'metadata': <String, dynamic>{},
                'createdAt': createdAt.toUtc().toIso8601String(),
                'acknowledged': false,
              },
            ],
            'meta': {'total': 1, 'page': 1, 'limit': 20},
          };

      await tester.pumpWidget(
        ProviderScope(
          overrides: [apiClientProvider.overrideWithValue(FakeApiClient(routes))],
          child: localizedTestApp(
            AlertsScreen(nowProvider: () => fixedNow),
            locale: locale,
            textDirection:
                locale.languageCode == 'ar' ? TextDirection.rtl : TextDirection.ltr,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await configureDateFormatting();
      expect(find.byType(AlertTile), findsOneWidget);

      await tester.tap(find.byType(AlertTile));
      await tester.pumpAndSettle();
    }

    testWidgets('EN dialog shows Category without Severity and relative #889 time without seconds',
        (tester) async {
      final en = lookupAppLocalizations(const Locale('en'));
      await pumpAlert(
        tester,
        locale: const Locale('en'),
        createdAt: DateTime(2026, 11, 20, 18, 9, 45),
      );

      expect(find.text(en.categoryLabel(en.alertCategoryTamper)), findsOneWidget);
      expect(find.textContaining('Severity'), findsNothing);

      final timeText =
          tester.widget<Text>(find.byKey(const ValueKey('alert-detail-time'))).data!;
      expect(timeText, 'Time: at \u{2066}18:09\u{2069}');
      expect(secondsRe.hasMatch(timeText), isFalse, reason: timeText);
      expect(tester.takeException(), isNull);
    });

    testWidgets('AR dialog shows الفئة without الخطورة and Western-digit #889 time without seconds',
        (tester) async {
      final ar = lookupAppLocalizations(const Locale('ar'));
      await pumpAlert(
        tester,
        locale: const Locale('ar'),
        createdAt: DateTime(2026, 11, 14, 16, 8, 43),
      );

      expect(find.text(ar.categoryLabel(ar.alertCategoryTamper)), findsOneWidget);
      expect(find.textContaining('الخطورة'), findsNothing);

      final timeText =
          tester.widget<Text>(find.byKey(const ValueKey('alert-detail-time'))).data!;
      expect(timeText, 'الوقت: يوم 14 نوفمبر الساعة \u{2066}16:08\u{2069}');
      expect(secondsRe.hasMatch(timeText), isFalse, reason: timeText);
      expect(arabicIndicDigits.hasMatch(timeText), isFalse, reason: timeText);
      expect(tester.takeException(), isNull);
    });
  });
}
