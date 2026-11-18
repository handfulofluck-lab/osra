import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:familyshield_parent/features/rules/rules_editor_screen.dart';
import 'package:familyshield_parent/l10n/app_localizations_ar.dart';
import 'package:familyshield_parent/providers/auth_provider.dart';
import 'package:familyshield_parent/theme/app_theme.dart';

import 'fake_api_client.dart';
import 'test_app.dart';

/// #872, Codex's AR 320 / 200 % frames: the Always-allowed chip and the routine chip cut the Bureaus'
/// fallback sentence mid-phrase. `InputChip` lays its label out with `maxHeight: contentSize`
/// (material/chip.dart) — one line — while the sentence needs two, and its label defaults to
/// `softWrap: false`, so the remainder fades.
///
/// These run the real screen at the real surface with a **real Arabic font** loaded into the engine.
/// The bundled test font has no Arabic glyphs, which is why the layout matrix alone could never see
/// this: every glyph was a box of the wrong width.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  /// The invariant: the sentence is laid out **whole** — either it fits the width it was given, or it
  /// wrapped onto a second line. Never ellipsised, never clipped by a one-line box.
  void expectWhole(WidgetTester tester, Finder finder, {required String reason}) {
    final paragraph = tester.renderObject<RenderParagraph>(finder);
    final neededWidth = paragraph.getMaxIntrinsicWidth(double.infinity);
    final neededHeight = paragraph.getMaxIntrinsicHeight(paragraph.size.width);
    expect(paragraph.didExceedMaxLines, isFalse, reason: '$reason: ellipsised');
    final fitsWidth = paragraph.size.width + 0.5 >= neededWidth;
    final fitsHeight = paragraph.size.height + 0.5 >= neededHeight;
    expect(
      fitsWidth || fitsHeight,
      isTrue,
      reason: '$reason: box ${paragraph.size} needs ${neededWidth}x$neededHeight',
    );
  }

  Future<void> pumpArabic(WidgetTester tester, FakeApiClient api, {double width = 320}) async {
    final bytes = File(r'C:\Windows\Fonts\tahoma.ttf').readAsBytesSync();
    await (FontLoader('ArReal')..addFont(Future.value(ByteData.view(bytes.buffer)))).load();

    tester.view.physicalSize = Size(width, 568);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(ProviderScope(
      overrides: [apiClientProvider.overrideWithValue(api)],
      child: localizedTestApp(
        Builder(
          builder: (c) => MediaQuery(
            data: MediaQuery.of(c).copyWith(textScaler: const TextScaler.linear(2.0)),
            child: const Directionality(
              textDirection: TextDirection.rtl,
              child: RulesEditorScreen(childId: 'child-1'),
            ),
          ),
        ),
        locale: const Locale('ar'),
        theme: AppTheme.light.copyWith(textTheme: AppTheme.light.textTheme.apply(fontFamily: 'ArReal')),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('AR 320/200%: the always-allowed fallback chip shows its sentence whole', (tester) async {
    final routes = standardRoutes();
    // A saved selection whose app the phone no longer reports: the state the Bureau's frames show.
    routes['GET /v1/rules/child-1'] =
        (_) => ruleSetPayload('child-1', alwaysAllowedApps: ['com.example.gone']);
    routes['GET /v1/devices/dev-1/apps'] =
        (_) => installedAppsPayload(apps: [installedAppJson('com.example.video', 'Video')]);

    await pumpArabic(tester, FakeApiClient(routes));
    DefaultTabController.of(tester.element(find.byType(TabBar))).animateTo(2);
    await tester.pumpAndSettle();

    final ar = AppLocalizationsAr();
    final label = find.text(ar.appNoLongerInstalled);
    expect(label, findsOneWidget);
    expectWhole(tester, label, reason: 'always-allowed chip');
    expect(find.text('com.example.gone'), findsNothing);
    expect(find.byTooltip(ar.appNoLongerInstalledRemove), findsOneWidget);
  });

  testWidgets('AR 320/200%: the routine dialog chip shows its sentence whole', (tester) async {
    final routes = standardRoutes();
    routes['GET /v1/rules/child-1'] = (_) {
      final payload = ruleSetPayload('child-1');
      payload['routines'] = [
        {
          'id': 'r1',
          'name': 'Homework',
          'startTime': '17:00',
          'endTime': '19:00',
          'days': [1, 2, 3],
          'blockedApps': ['com.example.gone'],
          'allowedApps': <String>[],
        },
      ];
      return payload;
    };
    routes['GET /v1/devices/dev-1/apps'] =
        (_) => installedAppsPayload(apps: [installedAppJson('com.example.video', 'Video')]);

    await pumpArabic(tester, FakeApiClient(routes));
    DefaultTabController.of(tester.element(find.byType(TabBar))).animateTo(3);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Homework'));
    await tester.pumpAndSettle();

    final label = find.text(AppLocalizationsAr().appNoLongerInstalled);
    expect(label, findsOneWidget);
    expectWhole(tester, label, reason: 'routine dialog chip');
  });

  /// **These rows are shape assertions, not mutants, and that is deliberate.** I checked: they pass on the
  /// old `InputChip` too, because Tahoma's Arabic is narrower than the device font Codex's frames used, so
  /// at these widths the sentence happened to fit one line and the chip escaped its own cap. A test that
  /// passes both ways proves nothing about the clip — the evidence for the defect is the frames plus
  /// Flutter's own layout (`maxHeight: contentSize`), and the evidence for the fix is Codex's re-shoot at
  /// the device font. What these rows do pin is the invariant and the wiring: the sentence is laid out
  /// whole, and the remove control keeps the Bureaus' tooltip.
  testWidgets('AR 280/200%: the sentence wraps instead of being cut', (tester) async {
    final routes = standardRoutes();
    routes['GET /v1/rules/child-1'] =
        (_) => ruleSetPayload('child-1', alwaysAllowedApps: ['com.example.gone']);
    routes['GET /v1/devices/dev-1/apps'] =
        (_) => installedAppsPayload(apps: [installedAppJson('com.example.video', 'Video')]);

    await pumpArabic(tester, FakeApiClient(routes), width: 280);
    DefaultTabController.of(tester.element(find.byType(TabBar))).animateTo(2);
    await tester.pumpAndSettle();

    final label = find.text(AppLocalizationsAr().appNoLongerInstalled);
    expect(label, findsOneWidget);
    expectWhole(tester, label, reason: 'always-allowed chip at 280');
    expect(tester.takeException(), isNull, reason: 'the chip must fit the surface, not overflow it');
  });
}
