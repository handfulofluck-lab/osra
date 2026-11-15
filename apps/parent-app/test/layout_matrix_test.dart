import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:familyshield_parent/features/children/child_detail_screen.dart';
import 'package:familyshield_parent/features/dashboard/dashboard_screen.dart';
import 'package:familyshield_parent/features/rules/rules_editor_screen.dart';
import 'package:familyshield_parent/l10n/l10n.dart';
import 'package:familyshield_parent/providers/auth_provider.dart';
import 'package:familyshield_parent/providers/onboarding_provider.dart';
import 'package:familyshield_parent/theme/app_theme.dart';

import 'fake_api_client.dart';

class MatrixConfig {
  final Size size;
  final double textScale;
  final Locale locale;
  final TextDirection textDirection;
  final ThemeData theme;
  final String themeName;

  const MatrixConfig({
    required this.size,
    required this.textScale,
    required this.locale,
    required this.textDirection,
    required this.theme,
    required this.themeName,
  });

  String get id =>
      '${size.width.toInt()}x${size.height.toInt()} | scale $textScale | ${locale.languageCode} | $themeName';
}

List<MatrixConfig> generateMatrix() {
  const sizes = [
    Size(320, 568),
    Size(375, 667),
    Size(393, 852),
  ];
  const scales = [1.0, 1.35, 2.0];
  const locales = [
    (Locale('en'), TextDirection.ltr),
    (Locale('ar'), TextDirection.rtl),
  ];
  final themes = [
    (AppTheme.light, 'light'),
    (AppTheme.dark, 'dark'),
  ];

  final matrix = <MatrixConfig>[];
  for (final size in sizes) {
    for (final scale in scales) {
      for (final (loc, dir) in locales) {
        for (final (theme, name) in themes) {
          matrix.add(MatrixConfig(
            size: size,
            textScale: scale,
            locale: loc,
            textDirection: dir,
            theme: theme,
            themeName: name,
          ));
        }
      }
    }
  }
  return matrix;
}

Future<bool> _loadSdkRobotoFont() async {
  Directory? dir = Directory(Platform.resolvedExecutable).parent;
  Directory? fontsDir;
  for (var i = 0; i < 8 && dir != null; i++) {
    final candidate = Directory('${dir.path}${Platform.pathSeparator}bin${Platform.pathSeparator}cache${Platform.pathSeparator}artifacts${Platform.pathSeparator}material_fonts');
    if (candidate.existsSync()) {
      fontsDir = candidate;
      break;
    }
    final directCandidate = Directory('${dir.path}${Platform.pathSeparator}material_fonts');
    if (directCandidate.existsSync()) {
      fontsDir = directCandidate;
      break;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  final envRoot = Platform.environment['FLUTTER_ROOT'];
  if (fontsDir == null && envRoot != null && envRoot.isNotEmpty) {
    final envCandidate = Directory('$envRoot${Platform.pathSeparator}bin${Platform.pathSeparator}cache${Platform.pathSeparator}artifacts${Platform.pathSeparator}material_fonts');
    if (envCandidate.existsSync()) fontsDir = envCandidate;
  }
  if (fontsDir == null) return false;

  final loader = FontLoader('Roboto');
  var loadedAny = false;
  for (final name in ['roboto-regular.ttf', 'roboto-medium.ttf', 'roboto-bold.ttf']) {
    final file = File('${fontsDir.path}${Platform.pathSeparator}$name');
    if (file.existsSync()) {
      final bytes = await file.readAsBytes();
      loader.addFont(Future.value(ByteData.sublistView(bytes)));
      loadedAny = true;
    }
  }
  if (!loadedAny) return false;
  await loader.load();
  return true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  var hasRoboto = false;
  setUpAll(() async {
    hasRoboto = await _loadSdkRobotoFont();
    expect(hasRoboto, isTrue, reason: 'SDK Roboto font must load so font metrics match device rendering');
  });

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({kOnboardingCompleteKey: true});
  });

  List<Object> drainExceptions(WidgetTester tester) {
    final exceptions = <Object>[];
    while (true) {
      final e = tester.takeException();
      if (e == null) return exceptions;
      exceptions.add(e);
    }
  }

  Future<void> flushFakeHttp(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  const testChildNameEn = 'Muhammed Mustafa Çağrı';
  const testChildNameAr = 'محمد مصطفى كاظم العلي';

  String childNameFor(Locale locale) =>
      locale.languageCode == 'ar' ? testChildNameAr : testChildNameEn;

  FakeApiClient buildTestApi({Locale locale = const Locale('en')}) {
    return FakeApiClient({
      ...standardRoutes(
        familyMe: familyMeTwoChildren(
          alexName: childNameFor(locale),
          alexModel: 'Pixel 7a',
        ),
      ),
      'GET /v1/reports/wellbeing/child-1': (_) => {
            'childId': 'child-1',
            'week': '2026-W37',
            'score': 85,
            'breakdown': {'usage': 90, 'social': 80, 'safety': 85},
          },
      'GET /v1/reports/wellbeing/child-2': (_) => {
            'childId': 'child-2',
            'week': '2026-W37',
            'score': 40,
            'breakdown': {'usage': 45, 'social': 40, 'safety': 35},
          },
    });
  }

  Widget buildApp({
    required MatrixConfig config,
    required FakeApiClient api,
    required GoRouter router,
  }) {
    return ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
      ],
      child: MaterialApp.router(
        routerConfig: router,
        locale: config.locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: hasRoboto
            ? config.theme.copyWith(
                textTheme: config.theme.textTheme.apply(fontFamily: 'Roboto'),
              )
            : config.theme,
        builder: (context, child) {
          return MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(config.textScale),
              size: config.size,
            ),
            child: Directionality(
              textDirection: config.textDirection,
              child: child!,
            ),
          );
        },
      ),
    );
  }

  group('Layout Matrix (36 Combinations: 3 sizes x 3 text scales x 2 locales x 2 themes)', () {
    final matrix = generateMatrix();
    assert(matrix.length == 36, 'Matrix must contain exactly 36 combinations');

    for (final config in matrix) {
      testWidgets('Dashboard Matrix Case: ${config.id}', (tester) async {
        tester.view.physicalSize = config.size;
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        final childName = childNameFor(config.locale);
        final api = buildTestApi(locale: config.locale);
        final dashboardRouter = GoRouter(
          initialLocation: '/',
          routes: [
            GoRoute(
              path: '/',
              builder: (_, __) => const DashboardScreen(),
            ),
            GoRoute(
              path: '/child/:id',
              builder: (_, state) => ChildDetailScreen(childId: state.pathParameters['id']!),
            ),
            GoRoute(
              path: '/child/:id/rules',
              builder: (_, state) => RulesEditorScreen(childId: state.pathParameters['id']!),
            ),
          ],
        );

        await tester.pumpWidget(buildApp(config: config, api: api, router: dashboardRouter));
        await flushFakeHttp(tester);
        await tester.pumpAndSettle();

        // 1. Zero render overflow assertion
        final exceptions = drainExceptions(tester);
        expect(exceptions, isEmpty, reason: 'Dashboard had layout overflow: ${exceptions.join("\n")}');

        // 2. Full child name present in widget tree on dashboard card
        final dashboardNameFinder = find.text(childName);
        expect(dashboardNameFinder, findsOneWidget, reason: 'Child name must be present in widget tree on dashboard card');

        // 3. Child name wraps up to 2 lines without truncation at standard scale (1.0)
        if (config.textScale == 1.0) {
          final dashboardRenderParagraph = tester.renderObject<RenderParagraph>(dashboardNameFinder);
          expect(
            dashboardRenderParagraph.didExceedMaxLines,
            isFalse,
            reason: 'Child name on dashboard card must wrap up to 2 lines without truncation at scale 1.0',
          );
        }

        // 4. Screen-time label/value and wellbeing score never truncate at 320 wide, scale 2.0 (EN/AR)
        final l10n = AppLocalizations.of(tester.element(find.byType(DashboardScreen)));
        final screenTimeLabels = tester.renderObjectList<RenderParagraph>(find.text(l10n.screenTime));
        expect(screenTimeLabels, isNotEmpty);
        for (final paragraph in screenTimeLabels) {
          expect(
            paragraph.didExceedMaxLines,
            isFalse,
            reason: 'Screen time label must not truncate with ellipsis at ${config.id}',
          );
        }
        if (config.size.width == 320 && config.textScale == 2.0) {
          final labelRect = tester.getRect(find.text(l10n.screenTime).first);
          final valueRect = tester.getRect(find.text(l10n.screenTimeValue(45, 120)));
          expect(
            valueRect.top,
            greaterThanOrEqualTo(labelRect.bottom),
            reason: 'Screen-time value must stack below the label at 320 / 2.0 (${config.id})',
          );
        }
        // Card 1 sits at the top of the list; verify it before scrolling down to card 2.
        for (final finder in [
          find.text(l10n.screenTimeValue(45, 120)),
          find.text(l10n.wellbeingScore(85)),
        ]) {
          final paragraph = tester.renderObject<RenderParagraph>(finder);
          expect(
            paragraph.didExceedMaxLines,
            isFalse,
            reason: 'Card 1 metrics must not truncate with ellipsis at ${config.id}',
          );
        }
        // Scroll downward to card 2 and verify both its screen-time value and wellbeing row.
        for (final finder in [
          find.text(l10n.screenTimeValue(10, 120)),
          find.text(l10n.wellbeingScore(40)),
        ]) {
          await tester.scrollUntilVisible(
            finder,
            150,
            scrollable: find.byType(Scrollable).first,
          );
          await tester.pumpAndSettle();
          final paragraph = tester.renderObject<RenderParagraph>(finder);
          expect(
            paragraph.didExceedMaxLines,
            isFalse,
            reason: 'Card 2 metrics must not truncate with ellipsis at ${config.id}',
          );
        }
        expect(drainExceptions(tester), isEmpty, reason: 'Dashboard overflowed after scroll (${config.id})');
      });

      testWidgets('Child Page Matrix Case: ${config.id}', (tester) async {
        tester.view.physicalSize = config.size;
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        final childName = childNameFor(config.locale);
        final api = buildTestApi(locale: config.locale);
        final childRouter = GoRouter(
          initialLocation: '/',
          routes: [
            GoRoute(
              path: '/',
              builder: (_, __) => const SizedBox.shrink(),
            ),
            GoRoute(
              path: '/child/:id',
              builder: (_, state) => ChildDetailScreen(childId: state.pathParameters['id']!),
            ),
            GoRoute(
              path: '/child/:id/rules',
              builder: (_, state) => RulesEditorScreen(childId: state.pathParameters['id']!),
            ),
          ],
        );

        await tester.pumpWidget(buildApp(config: config, api: api, router: childRouter));
        childRouter.push('/child/child-1');
        await flushFakeHttp(tester);
        await tester.pumpAndSettle();

        // 1. Zero render overflow assertion
        final exceptions = drainExceptions(tester);
        expect(exceptions, isEmpty, reason: 'Child Detail screen had layout overflow: ${exceptions.join("\n")}');

        // 2. Full child name present in AppBar semantics & widget tree; zero truncation at scale 1.0 across all widths;
        // Overview card displays full child name with no line limit at every scale (including 320 / 2.0).
        final topBarNameFinder = find.descendant(
          of: find.byType(AppBar),
          matching: find.text(childName),
        );
        expect(topBarNameFinder, findsOneWidget, reason: 'Child name must be present in AppBar title widget tree');
        expect(
          tester.getSemantics(topBarNameFinder).label,
          contains(childName),
          reason: 'AppBar title semantics must preserve the full child name (${config.id})',
        );
        if (config.textScale == 1.0) {
          final topBarParagraph = tester.renderObject<RenderParagraph>(topBarNameFinder);
          expect(
            topBarParagraph.didExceedMaxLines,
            isFalse,
            reason: 'Child name in AppBar must wrap up to 2 lines without truncation at scale 1.0 (${config.id})',
          );
        }
        final overviewCardNameFinder = find.descendant(
          of: find.byType(Card).first,
          matching: find.text(childName),
        );
        expect(overviewCardNameFinder, findsOneWidget, reason: 'Overview card must render full child name (${config.id})');
        expect(
          tester.widget<Text>(overviewCardNameFinder).maxLines,
          isNull,
          reason: 'Overview card child name must have no maxLines cap (${config.id})',
        );
        expect(
          tester.renderObject<RenderParagraph>(overviewCardNameFinder).didExceedMaxLines,
          isFalse,
          reason: 'Overview card child name must wrap freely without truncation (${config.id})',
        );

        // 3. AppBar actions: below 360dp folded into 48dp overflow menu; >=360dp keeps direct 48dp IconButtons
        if (config.size.width < 360) {
          final menuBtnFinder = find.byKey(const ValueKey('childActionsMenu'));
          expect(menuBtnFinder, findsOneWidget, reason: 'childActionsMenu overflow button must exist below 360dp');
          final menuBtnSize = tester.getSize(menuBtnFinder);
          expect(menuBtnSize.width, greaterThanOrEqualTo(48.0), reason: 'childActionsMenu width >= 48 dp');
          expect(menuBtnSize.height, greaterThanOrEqualTo(48.0), reason: 'childActionsMenu height >= 48 dp');
          await tester.tap(menuBtnFinder);
          await tester.pumpAndSettle();
          final l10n = AppLocalizations.of(tester.element(find.byType(ChildDetailScreen)));
          expect(find.descendant(of: find.byType(PopupMenuItem<String>), matching: find.text(l10n.reportsTooltip)), findsOneWidget);
          expect(find.descendant(of: find.byType(PopupMenuItem<String>), matching: find.text(l10n.searchSafetyTooltip)), findsOneWidget);
          expect(find.descendant(of: find.byType(PopupMenuItem<String>), matching: find.text(l10n.editRules)), findsOneWidget);
          expect(drainExceptions(tester), isEmpty, reason: 'Child actions popup menu must not overflow at ${config.id}');
        } else {
          final iconBtnFinder = find.byKey(const ValueKey('editRulesButton'));
          expect(iconBtnFinder, findsOneWidget, reason: 'editRulesButton IconButton must exist in AppBar actions');

          final iconBtnSize = tester.getSize(iconBtnFinder);
          expect(
            iconBtnSize.width,
            greaterThanOrEqualTo(48.0),
            reason: 'editRulesButton width ${iconBtnSize.width} must be at least 48 dp',
          );
          expect(
            iconBtnSize.height,
            greaterThanOrEqualTo(48.0),
            reason: 'editRulesButton height ${iconBtnSize.height} must be at least 48 dp',
          );
        }

        // 4. Overview Tab full-width tonal button assertion
        final overviewBtnFinder = find.byKey(const ValueKey('overviewEditRulesButton'));
        expect(overviewBtnFinder, findsOneWidget, reason: 'overviewEditRulesButton must exist in Overview tab');
      });
    }
  });
}
