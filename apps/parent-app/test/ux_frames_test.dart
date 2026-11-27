import 'package:familyshield_parent/features/dashboard/dashboard_screen.dart';
import 'package:familyshield_parent/features/settings/settings_screen.dart';
import 'package:familyshield_parent/features/social/social_screen.dart';
import 'package:familyshield_parent/providers/auth_provider.dart';
import 'package:familyshield_parent/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_api_client.dart';
import 'social_app_fixtures.dart';
import 'frame_capture.dart';
import 'test_app.dart';

/// Frames for the UI/UX Bureau, produced by CI into `OSRA_FRAME_DIR` (Claude, 20:46 UAE: P-17 and P-22 first,
/// because P-09 already has Codex's signed frames).
///
/// These rows render the screens at the two widths and two themes the Bureau signs against, and write a PNG for
/// each. With `OSRA_FRAME_DIR` unset — every ordinary CI run and every local run — `maybeCaptureFrame` returns
/// without writing anything, so the rows still prove that nothing overflows at 320 px / 200 %.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(loadFrameFonts);

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  Future<void> pumpFrame(
    WidgetTester tester,
    Widget home, {
    required Locale locale,
    required bool dark,
    required double width,
    required double textScale,
    required Map<String, dynamic> family,
    bool uxP22 = true,
  }) async {
    // B1: seed the two preferences the Settings values read, so the frame shows a chosen
    // language and theme rather than 'System' on both rows.
    SharedPreferences.setMockInitialValues({
      'app_locale': locale.languageCode,
      'theme_mode': dark ? 'dark' : 'light',
    });
    tester.view.physicalSize = Size(width, width >= 380 ? 1400 : 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    // P-17's frames are about the per-app state rows, so the child must have social apps installed; the plain
    // standard routes would show all twelve as "not on the phone" and photograph nothing.
    final api = FakeApiClient({
      ...standardRoutes(familyMe: family),
      'GET /v1/devices/dev-1/apps': (_) => installedAppsPayload(
            apps: socialInventory({'whatsapp', 'instagram', 'tiktok', 'youtube'}),
          ),
      'GET /v1/devices/dev-2/apps': (_) => installedAppsPayload(apps: const []),
    });
    // The boundary goes around the whole app, not around the screen: a dialog is painted in the app's overlay,
    // above the screen, and a boundary on the screen alone photographs the screen and silently drops the dialog.
    final app = RepaintBoundary(
      key: const ValueKey('frameRoot'),
      child: localizedTestApp(
        MediaQuery(
          data: MediaQueryData(
            size: Size(width, width >= 380 ? 1400 : 1200),
            textScaler: TextScaler.linear(textScale),
          ),
          child: home,
        ),
        locale: locale,
        theme: withFrameFonts(dark ? AppTheme.dark : AppTheme.light),
      ),
    );
    await tester.pumpWidget(ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        p17SocialEnabledProvider.overrideWithValue(true),
        p22SettingsEnabledProvider.overrideWithValue(uxP22),
      ],
      child: app,
    ));
    await tester.pumpAndSettle();
  }

  Map<String, dynamic> familyWith({bool twoStepOn = true}) {
    final family = familyMeTwoChildren();
    // The time zone row reads this; without it the frame shows the honest fallback, not the value.
    family['family'] = {
      ...(family['family'] as Map<String, dynamic>),
      'utcOffsetMinutes': 240,
    };
    family['parent'] = {
      ...(family['parent'] as Map<String, dynamic>),
      'mfaEnabled': twoStepOn,
    };
    return family;
  }


  testWidgets('P-22 settings card shown en-light-390', (tester) async {
    await pumpFrame(
      tester,
      const SettingsScreen(),
      locale: const Locale('en'),
      dark: false,
      width: 390,
      textScale: 1,
      family: familyWith(twoStepOn: false),
    );
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('settingsSecurityCard')), findsOneWidget);
    await maybeCaptureFrame(tester, 'p22-settings-card-shown-en-light-390.png');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('P-22 settings card shown ar-dark-390', (tester) async {
    await pumpFrame(
      tester,
      const SettingsScreen(),
      locale: const Locale('ar'),
      dark: true,
      width: 390,
      textScale: 1,
      family: familyWith(twoStepOn: false),
    );
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('settingsSecurityCard')), findsOneWidget);
    await maybeCaptureFrame(tester, 'p22-settings-card-shown-ar-dark-390.png');
    await tester.pumpWidget(const SizedBox());
  });


  testWidgets('P-22 sign-out confirm dialog en-light-390', (tester) async {
    await pumpFrame(
      tester,
      const SettingsScreen(),
      locale: const Locale('en'),
      dark: false,
      width: 390,
      textScale: 1,
      family: familyWith(),
    );
    await tester.tap(find.byKey(const ValueKey('settingsRow-signOutAll')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('settingsSignOutAllDialog')), findsOneWidget);
    await maybeCaptureFrame(tester, 'p22-settings-signout-dialog-en-light-390.png');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('P-22 with the switch off en-light-390', (tester) async {
    await pumpFrame(
      tester,
      const SettingsScreen(),
      locale: const Locale('en'),
      dark: false,
      width: 390,
      textScale: 1,
      family: familyWith(),
      uxP22: false,
    );
    expect(tester.takeException(), isNull);
    await maybeCaptureFrame(tester, 'p22-settings-flag-off-en-light-390.png');
    await tester.pumpWidget(const SizedBox());
  });


  testWidgets('P-22 dashboard menu with the flag on en-light-390', (tester) async {
    await pumpFrame(
      tester,
      const DashboardScreen(),
      locale: const Locale('en'),
      dark: false,
      width: 390,
      textScale: 1,
      family: familyWith(),
    );
    await tester.tap(find.byType(PopupMenuButton<String>).first);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('dashboardMenu-settings')), findsOneWidget);
    await maybeCaptureFrame(tester, 'p22-menu-on-en-light-390.png');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('P-22 dashboard menu with the flag off en-light-390', (tester) async {
    await pumpFrame(
      tester,
      const DashboardScreen(),
      locale: const Locale('en'),
      dark: false,
      width: 390,
      textScale: 1,
      family: familyWith(),
      uxP22: false,
    );
    await tester.tap(find.byType(PopupMenuButton<String>).first);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('dashboardMenu-settings')), findsNothing);
    await maybeCaptureFrame(tester, 'p22-menu-off-en-light-390.png');
    await tester.pumpWidget(const SizedBox());
  });

  for (final config in const [
    (locale: 'en', dark: false, width: 390.0, scale: 1.0, tag: 'en-light-390'),
    (locale: 'ar', dark: true, width: 390.0, scale: 1.0, tag: 'ar-dark-390'),
    (locale: 'en', dark: false, width: 320.0, scale: 2.0, tag: 'en-light-320-200'),
    (locale: 'ar', dark: true, width: 320.0, scale: 2.0, tag: 'ar-dark-320-200'),
  ]) {
    testWidgets('P-17 social monitoring ${config.tag}', (tester) async {
      await pumpFrame(
        tester,
        const SocialScreen(childId: 'child-1'),
        locale: Locale(config.locale),
        dark: config.dark,
        width: config.width,
        textScale: config.scale,
        family: familyWith(),
      );
      expect(tester.takeException(), isNull,
          reason: 'no overflow at ${config.width} px / ${config.scale}x');
      await maybeCaptureFrame(tester, 'p17-social-${config.tag}.png');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('P-22 settings ${config.tag}', (tester) async {
      await pumpFrame(
        tester,
        const SettingsScreen(),
        locale: Locale(config.locale),
        dark: config.dark,
        width: config.width,
        textScale: config.scale,
        family: familyWith(),
      );
      expect(tester.takeException(), isNull,
          reason: 'no overflow at ${config.width} px / ${config.scale}x');
      await maybeCaptureFrame(tester, 'p22-settings-${config.tag}.png');
      await tester.pumpWidget(const SizedBox());
    });
  }
}
