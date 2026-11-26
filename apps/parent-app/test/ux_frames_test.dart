import 'package:familyshield_parent/features/settings/settings_screen.dart';
import 'package:familyshield_parent/features/social/social_screen.dart';
import 'package:familyshield_parent/providers/auth_provider.dart';
import 'package:familyshield_parent/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_api_client.dart';
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
  }) async {
    tester.view.physicalSize = Size(width, width >= 380 ? 1400 : 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final api = FakeApiClient(standardRoutes(familyMe: family));
    await tester.pumpWidget(ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        p17SocialEnabledProvider.overrideWithValue(true),
        p22SettingsEnabledProvider.overrideWithValue(true),
      ],
      child: localizedTestApp(
        RepaintBoundary(
          key: const ValueKey('frameRoot'),
          child: MediaQuery(
            data: MediaQueryData(
              size: Size(width, width >= 380 ? 1400 : 1200),
              textScaler: TextScaler.linear(textScale),
            ),
            child: home,
          ),
        ),
        locale: locale,
        theme: withFrameFonts(dark ? AppTheme.dark : AppTheme.light),
      ),
    ));
    await tester.pumpAndSettle();
  }

  Map<String, dynamic> familyWith({bool twoStepOn = true}) {
    final family = familyMeTwoChildren();
    family['parent'] = {
      ...(family['parent'] as Map<String, dynamic>),
      'mfaEnabled': twoStepOn,
    };
    return family;
  }

  for (final config in const [
    (locale: 'en', dark: false, width: 390.0, scale: 1.0, tag: 'en-light-390'),
    (locale: 'ar', dark: true, width: 390.0, scale: 1.0, tag: 'ar-dark-390'),
    (locale: 'en', dark: false, width: 320.0, scale: 2.0, tag: 'en-light-320-200'),
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
