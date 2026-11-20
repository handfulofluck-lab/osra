import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:familyshield_parent/api/models.dart';
import 'package:familyshield_parent/features/alerts/alerts_screen.dart';
import 'package:familyshield_parent/features/children/child_detail_screen.dart'
    show AlertTile;
import 'package:familyshield_parent/l10n/l10n.dart';
import 'package:familyshield_parent/providers/auth_provider.dart';
import 'package:familyshield_parent/push/local_notifier.dart';
import 'package:familyshield_parent/push/ring_volume_alert_text.dart';

import 'fake_api_client.dart';
import 'test_app.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  Alert ringVolumeAlert({
    required int count,
    String? childName,
  }) =>
      Alert(
        id: 'alert-rv-$count',
        childId: 'child-1',
        deviceId: 'dev-1',
        severity: 'info',
        category: 'ring_volume',
        title: 'Tried to turn the ring down',
        body: 'SERVER FALLBACK',
        createdAt: DateTime.utc(2026, 11, 20, 1, 15),
        attemptCount: count,
        metadata: {
          'type': 'ring_volume',
          'count': '$count',
          if (childName != null) 'childName': childName,
        },
      );

  group('RingVolumeAlertText (osra-security#42 / #944 EN & AR Bureau copy)', () {
    late AppLocalizations en;
    late AppLocalizations ar;

    setUpAll(() async {
      en = await AppLocalizations.delegate.load(const Locale('en'));
      ar = await AppLocalizations.delegate.load(const Locale('ar'));
    });

    test('formats EN count=1 and count=5 with FSI/PDI isolation around child name', () {
      expect(
        RingVolumeAlertText.tryFormat(ringVolumeAlert(count: 1), l10n: en, childName: 'سارة'),
        '\u{2068}سارة\u{2069} tried to turn down the ring volume once. The phone kept ringing.',
      );
      expect(
        RingVolumeAlertText.tryFormat(ringVolumeAlert(count: 5), l10n: en, childName: 'Sam'),
        '\u{2068}Sam\u{2069} tried to turn down the ring volume 5 times. The phone kept ringing.',
      );
    });

    test('formats AR count=1, 2, 5, 11 with Bureau plurals, Western digits, and FSI/PDI isolation', () {
      final one = RingVolumeAlertText.tryFormat(ringVolumeAlert(count: 1), l10n: ar, childName: 'Alex');
      final two = RingVolumeAlertText.tryFormat(ringVolumeAlert(count: 2), l10n: ar, childName: 'Alex');
      final five = RingVolumeAlertText.tryFormat(ringVolumeAlert(count: 5), l10n: ar, childName: 'Alex');
      final eleven = RingVolumeAlertText.tryFormat(ringVolumeAlert(count: 11), l10n: ar, childName: 'Alex');

      expect(one, 'سُجّلت محاولة واحدة لخفض صوت الرنين على هاتف \u{2068}Alex\u{2069}، وظلّ الهاتف يرنّ.');
      expect(two, 'سُجّلت محاولتان لخفض صوت الرنين على هاتف \u{2068}Alex\u{2069}، وظلّ الهاتف يرنّ.');
      expect(five, 'سُجّلت 5 محاولات لخفض صوت الرنين على هاتف \u{2068}Alex\u{2069}، وظلّ الهاتف يرنّ.');
      expect(eleven, 'سُجّلت 11 محاولة لخفض صوت الرنين على هاتف \u{2068}Alex\u{2069}، وظلّ الهاتف يرنّ.');

      for (final s in [one!, two!, five!, eleven!]) {
        expect(RegExp(r'[\u0660-\u0669\u06F0-\u06F9]').hasMatch(s), isFalse);
      }
    });

    test('VisibleAlert.from translates title and body without leaking server fallback text', () {
      final visibleAr = VisibleAlert.from(
        ringVolumeAlert(count: 5, childName: 'Alex'),
        l10n: ar,
        isEnglish: false,
      );
      expect(visibleAr.title, ar.alertRingVolumeTitle);
      expect(visibleAr.body, contains('5 محاولات'));
      expect(visibleAr.body, contains('\u{2068}Alex\u{2069}'));
      expect(visibleAr.body, isNot(contains('SERVER FALLBACK')));
    });
  });

  group('AlertsScreen ring_volume rows & dialogs at 320x568 / 200%', () {
    Future<void> pumpAlert(
      WidgetTester tester,
      Locale locale,
      int count, {
      String childName = 'Sam',
    }) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1.0;
      tester.platformDispatcher.textScaleFactorTestValue = 2.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        tester.platformDispatcher.clearTextScaleFactorTestValue();
      });

      final alert = ringVolumeAlert(count: count);
      final routes = standardRoutes();
      routes['GET /v1/family/me'] = (_) => familyMeTwoChildren(alexName: childName);
      routes['GET /v1/alerts'] = (_) => {
            'items': [
              {
                'id': alert.id,
                'childId': alert.childId,
                'deviceId': alert.deviceId,
                'severity': alert.severity,
                'category': alert.category,
                'title': alert.title,
                'body': alert.body,
                'metadata': alert.metadata,
                'attemptCount': alert.attemptCount,
                'createdAt': alert.createdAt?.toUtc().toIso8601String(),
                'acknowledged': false,
              },
            ],
            'meta': {'total': 1, 'page': 1, 'limit': 20},
          };

      await tester.pumpWidget(ProviderScope(
        overrides: [apiClientProvider.overrideWithValue(FakeApiClient(routes))],
        child: localizedTestApp(
          const AlertsScreen(),
          locale: locale,
          textDirection: locale.languageCode == 'ar' ? TextDirection.rtl : TextDirection.ltr,
        ),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('EN count=1 renders category chip and dialog body cleanly at 320x568 / 200%', (tester) async {
      await pumpAlert(tester, const Locale('en'), 1, childName: 'سارة');
      expect(find.byType(AlertTile), findsOneWidget);
      expect(find.text('Tried to turn the ring down'), findsOneWidget);
      expect(find.textContaining('Ring volume ·'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.tap(find.byType(AlertTile));
      await tester.pumpAndSettle();
      expect(find.text('\u{2068}سارة\u{2069} tried to turn down the ring volume once. The phone kept ringing.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('EN count=5 renders plural dialog body cleanly at 320x568 / 200%', (tester) async {
      await pumpAlert(tester, const Locale('en'), 5, childName: 'Sam');
      expect(find.byType(AlertTile), findsOneWidget);
      expect(find.text('Tried to turn the ring down'), findsOneWidget);
      expect(find.textContaining('Ring volume ·'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.tap(find.byType(AlertTile));
      await tester.pumpAndSettle();
      expect(find.text('\u{2068}Sam\u{2069} tried to turn down the ring volume 5 times. The phone kept ringing.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('AR count=1 renders Arabic Bureau chip and dialog body cleanly at 320x568 / 200%', (tester) async {
      await pumpAlert(tester, const Locale('ar'), 1, childName: 'Alex');
      expect(find.byType(AlertTile), findsOneWidget);
      expect(find.text('محاولة لخفض صوت الرنين'), findsOneWidget);
      expect(find.textContaining('صوت الرنين ·'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.tap(find.byType(AlertTile));
      await tester.pumpAndSettle();
      expect(find.text('سُجّلت محاولة واحدة لخفض صوت الرنين على هاتف \u{2068}Alex\u{2069}، وظلّ الهاتف يرنّ.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('AR count=5 renders Arabic Bureau plural dialog body cleanly at 320x568 / 200%', (tester) async {
      await pumpAlert(tester, const Locale('ar'), 5, childName: 'Alex');
      expect(find.byType(AlertTile), findsOneWidget);
      expect(find.text('محاولة لخفض صوت الرنين'), findsOneWidget);
      expect(find.textContaining('صوت الرنين ·'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.tap(find.byType(AlertTile));
      await tester.pumpAndSettle();
      expect(find.text('سُجّلت 5 محاولات لخفض صوت الرنين على هاتف \u{2068}Alex\u{2069}، وظلّ الهاتف يرنّ.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
