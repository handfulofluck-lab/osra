import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:familyshield_parent/api/models.dart';
import 'package:familyshield_parent/features/alerts/alerts_screen.dart';
import 'package:familyshield_parent/features/children/child_detail_screen.dart' show AlertTile;
import 'package:familyshield_parent/providers/auth_provider.dart';
import 'package:familyshield_parent/theme/app_theme.dart';

import 'fake_api_client.dart';
import 'frame_capture.dart';
import 'test_app.dart';

Map<String, dynamic> _ringAlertJson(DateTime at) => {
      'id': 'ring-1',
      'childId': 'child-1',
      'deviceId': 'dev-1',
      'severity': 'info',
      'category': 'ring',
      'title': 'Phone ring',
      'body': 'The ring ended by itself after 5 minutes.',
      'metadata': {
        'state': 'timed_out',
        'ringId': 'ring-1',
        'bodyKey': 'alertBodyRingTimedOut',
        'bodyParams': {'ringId': 'ring-1'},
      },
      'createdAt': at.toUtc().toIso8601String(),
      'acknowledged': false,
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Real faces for every frame: without them the binding draws solid blocks, and the run still "passes"
  // (#760). Both families are required because every row below draws either Latin or Arabic text.
  setUpAll(() => loadFrameFonts(required: const {'Roboto', 'NotoNaskhArabicUI'}));

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  const size = Size(375, 812);

  Future<void> pump(
    WidgetTester tester,
    Widget home, {
    required Locale locale,
    required ThemeMode themeMode,
    TextDirection? textDirection,
    Size logical = size,
    double textScale = 1.0,
  }) async {
    // `physicalSize` is in device pixels, so a 375 × 812 surface at 2× is 750 × 1624 here. Setting 375 × 812
    // gave a 187.5 × 406 surface and every frame came out half-size (#760).
    tester.view.physicalSize = logical * 2.0;
    tester.view.devicePixelRatio = 2.0;
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      tester.platformDispatcher.clearTextScaleFactorTestValue();
    });
    await tester.pumpWidget(ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(FakeApiClient(standardRoutes(
          alerts: [_ringAlertJson(DateTime.utc(2026, 11, 16, 10, 0, 0))],
        )))
      ],
      child: localizedTestApp(
        home,
        locale: locale,
        textDirection: textDirection,
        theme: withFrameFonts(AppTheme.light),
        darkTheme: withFrameFonts(AppTheme.dark),
        themeMode: themeMode,
      ),
    ));
    await tester.pumpAndSettle();
  }

  Alert _ringAlert() => Alert(
        id: 'ring-1',
        childId: 'c1',
        deviceId: 'dev-1',
        severity: 'info',
        category: 'ring',
        title: 'Phone ring',
        body: 'The ring ended by itself after 5 minutes.',
        metadata: const {
          'state': 'timed_out',
          'ringId': 'ring-1',
          'bodyKey': 'alertBodyRingTimedOut',
          'bodyParams': {'ringId': 'ring-1'},
        },
        createdAt: DateTime.utc(2026, 11, 16, 10, 0, 0),
      );

  for (final locale in const [Locale('en'), Locale('ar')]) {
    for (final themeMode in ThemeMode.values.where((m) => m != ThemeMode.system)) {
      final suffix = '${locale.languageCode}_${themeMode.name}';
      final rtl = locale.languageCode == 'ar' ? TextDirection.rtl : null;

      testWidgets('ring AlertTile $suffix', (tester) async {
        await pump(tester, Scaffold(body: AlertTile(alert: _ringAlert())),
            locale: locale, themeMode: themeMode, textDirection: rtl);
        await expectLater(
          find.byType(AlertTile),
          matchesGoldenFile('goldens/ring_alert_tile_$suffix.png'),
        );
      });

      // The Arabic Language Bureau's row (#760): the narrowest surface the parent app supports at the largest
      // text size. An overflow here is a real defect and fails the run rather than hiding in a picture.
      if (locale.languageCode == 'ar') {
        testWidgets('ring AlertTile $suffix at 320 pt and 200 % text', (tester) async {
          await pump(tester, Scaffold(body: AlertTile(alert: _ringAlert())),
              locale: locale,
              themeMode: themeMode,
              textDirection: rtl,
              logical: const Size(320, 640),
              textScale: 2.0);
          await expectLater(
            find.byType(AlertTile),
            matchesGoldenFile('goldens/ring_alert_tile_${suffix}_320_200.png'),
          );
        });
      }

      testWidgets('ring alert detail $suffix', (tester) async {
        await pump(tester, const AlertsScreen(), locale: locale, themeMode: themeMode, textDirection: rtl);
        await tester.pumpAndSettle();
        await tester.tap(find.text(locale.languageCode == 'ar' ? 'رنين الهاتف' : 'Phone ring'));
        await tester.pumpAndSettle();
        await expectLater(
          find.byType(AlertDialog),
          matchesGoldenFile('goldens/ring_alert_detail_$suffix.png'),
        );
      });
    }
  }
}
