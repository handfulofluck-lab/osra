import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:familyshield_parent/api/models.dart';
import 'package:familyshield_parent/features/alerts/alerts_screen.dart';
import 'package:familyshield_parent/features/children/child_detail_screen.dart' show AlertTile;
import 'package:familyshield_parent/l10n/l10n.dart';
import 'package:familyshield_parent/providers/auth_provider.dart';
import 'package:familyshield_parent/theme/app_theme.dart';

import 'fake_api_client.dart';
import 'test_app.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 2.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(ProviderScope(
      overrides: [apiClientProvider.overrideWithValue(FakeApiClient(standardRoutes()))],
      child: localizedTestApp(
        home,
        locale: locale,
        textDirection: textDirection,
        theme: AppTheme.light,
        darkTheme: AppTheme.dark,
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
