import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
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
/// **No font is loaded, on purpose.** An earlier version of this file read Tahoma from
/// `C:\Windows\Fonts`, which made two things true at once: it only ran on this PC, and it made CI red on
/// every runner (Kimi's `parent-app` failure at `5e9094ff`). The engine's default test font draws every
/// glyph as a box, which is wider than any real Arabic — so the sentence wraps here for a reason that
/// does not depend on which machine is running, and the rows exercise the same layout path.
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
        theme: AppTheme.light,
      ),
    ));
    // Dio resolves through chained zero-duration timers, so a bare pumpAndSettle can return before the
    // rules and the device report land — the same flush `installed_apps_picker_test.dart` uses.
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
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
    // 320 px at 200 % puts the Always-allowed section below the fold, and the Apps tab is a lazy list:
    // the chip is not built until it is scrolled into view.
    await tester.scrollUntilVisible(
      find.text(ar.appNoLongerInstalled),
      200,
      scrollable: find.byWidgetPredicate((w) => w is Scrollable && w.axis == Axis.vertical).first,
    );
    await tester.pumpAndSettle();
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

    final ar = AppLocalizationsAr();
    if (find.text(ar.appNoLongerInstalled).evaluate().isEmpty) {
      await tester.scrollUntilVisible(
        find.text(ar.appNoLongerInstalled),
        100,
        scrollable: find.descendant(of: find.byType(AlertDialog), matching: find.byType(Scrollable)).first,
      );
      await tester.pumpAndSettle();
    }
    final label = find.text(ar.appNoLongerInstalled);
    expect(label, findsOneWidget);
    expectWhole(tester, label, reason: 'routine dialog chip');
  });

  /// **What these rows prove, and what they do not.** The clip needs a device font to reproduce, so the
  /// evidence for the defect is Codex's frames plus Flutter's own layout (`maxHeight: contentSize`), and
  /// for the fix, Codex's re-shoot. What the rows pin is the invariant and the wiring: the sentence is
  /// laid out whole wherever it appears, and the remove control keeps the Bureaus' tooltip. The English
  /// case is a real mutant — restoring `maxLines: 2` turns it red, because three lines are needed.
  /// Codex's second retest: the English label needs **three** lines in the narrower routine dialog at
  /// 320/200 %. A two-line cap moved the cut rather than removing it, so the row below checks the whole
  /// sentence on the surface that exposed it.
  testWidgets('EN 320/200%: the routine dialog shows the English sentence whole', (tester) async {
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

    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(ProviderScope(
      overrides: [apiClientProvider.overrideWithValue(FakeApiClient(routes))],
      child: localizedTestApp(
        Builder(
          builder: (c) => MediaQuery(
            data: MediaQuery.of(c).copyWith(textScaler: const TextScaler.linear(2.0)),
            child: const RulesEditorScreen(childId: 'child-1'),
          ),
        ),
        locale: const Locale('en'),
      ),
    ));
    await tester.pumpAndSettle();
    DefaultTabController.of(tester.element(find.byType(TabBar))).animateTo(3);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Homework'));
    await tester.pumpAndSettle();

    final label = find.text('App no longer installed');
    expect(label, findsOneWidget);
    expectWhole(tester, label, reason: 'English routine dialog chip');
    expect(tester.takeException(), isNull);
  });
}
