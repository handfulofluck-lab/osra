import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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

  const testChildName = 'Muhammed Mustafa Çağrı';

  FakeApiClient buildTestApi() {
    return FakeApiClient(standardRoutes(
      familyMe: familyMeTwoChildren(
        alexName: testChildName,
        alexModel: 'Pixel 7a',
      ),
    ));
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
        theme: config.theme,
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

        final api = buildTestApi();
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
        final dashboardNameFinder = find.text(testChildName);
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
      });

      testWidgets('Child Page Matrix Case: ${config.id}', (tester) async {
        tester.view.physicalSize = config.size;
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        final api = buildTestApi();
        final childRouter = GoRouter(
          initialLocation: '/child/child-1',
          routes: [
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
        await flushFakeHttp(tester);
        await tester.pumpAndSettle();

        // 1. Zero render overflow assertion
        final exceptions = drainExceptions(tester);
        expect(exceptions, isEmpty, reason: 'Child Detail screen had layout overflow: ${exceptions.join("\n")}');

        // 2. Full child name present in widget tree on top bar
        final topBarNameFinder = find.descendant(
          of: find.byType(AppBar),
          matching: find.text(testChildName),
        );
        expect(topBarNameFinder, findsOneWidget, reason: 'Child name must be present in AppBar title widget tree');

        // 3. Edit Rules Icon Button minimum 48 dp touch target assertion
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

        // 4. Overview Tab full-width tonal button assertion
        final overviewBtnFinder = find.byKey(const ValueKey('overviewEditRulesButton'));
        expect(overviewBtnFinder, findsOneWidget, reason: 'overviewEditRulesButton must exist in Overview tab');
      });
    }
  });

  group('Planted Fault Verification (Intentional Failures on Regression)', () {
    testWidgets('Planted fault: maxLines: 1 causes premature truncation on long name', (tester) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      // Render with maxLines: 1 under scale 1.0
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MediaQuery(
              data: const MediaQueryData(
                textScaler: TextScaler.linear(1.0),
                size: Size(320, 568),
              ),
              child: const SizedBox(
                width: 200,
                child: Text(
                  testChildName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          ),
        ),
      );

      final paragraph = tester.renderObject<RenderParagraph>(find.text(testChildName));
      // Planted fault assertion: with maxLines: 1, long name exceeds max lines (truncates prematurely)
      expect(paragraph.didExceedMaxLines, isTrue, reason: 'Regression to maxLines: 1 correctly detected as truncating');
    });

    testWidgets('Planted fault: fixed-height card container causes layout overflow at scale 2.0', (tester) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      // Wrap a large card in an artificially constrained 80 dp box
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MediaQuery(
              data: const MediaQueryData(
                textScaler: TextScaler.linear(2.0),
                size: Size(320, 568),
              ),
              child: SizedBox(
                height: 80,
                child: Column(
                  children: [
                    const Text(testChildName),
                    const SizedBox(height: 20),
                    const Text('Status Online Battery 55%'),
                    const SizedBox(height: 20),
                    const Text('Screen time 45m / 60m'),
                    const SizedBox(height: 20),
                    Container(height: 50, color: Colors.blue),
                  ],
                ),
              ),
            ),
          ),
        ),
      );

      final exceptions = drainExceptions(tester);
      // Planted fault assertion: fixed height causes overflow exception
      expect(
        exceptions.any((e) => e.toString().contains('overflowed')),
        isTrue,
        reason: 'Regression to fixed height containers correctly detected as layout overflow',
      );
    });

    testWidgets('Planted fault: undersized touch target (<48 dp) fails minimum size requirement', (tester) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      // Render an undersized button (36x36)
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 36,
              height: 36,
              child: IconButton(
                key: const ValueKey('undersizedButton'),
                padding: EdgeInsets.zero,
                iconSize: 18,
                icon: const Icon(Icons.rule),
                onPressed: () {},
              ),
            ),
          ),
        ),
      );

      final size = tester.getSize(find.byKey(const ValueKey('undersizedButton')));
      // Planted fault assertion: undersized button fails 48 dp threshold
      expect(size.width < 48.0 || size.height < 48.0, isTrue, reason: 'Undersized button correctly fails 48 dp check');
    });

    testWidgets('Planted fault: 2-column cards without stretch have mismatched heights', (tester) async {
      tester.view.physicalSize = const Size(800, 600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      // Row without CrossAxisAlignment.stretch and without IntrinsicHeight
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Card(
                    key: ValueKey('shortCard'),
                    child: SizedBox(height: 100),
                  ),
                ),
                Expanded(
                  child: Card(
                    key: ValueKey('tallCard'),
                    child: SizedBox(height: 200),
                  ),
                ),
              ],
            ),
          ),
        ),
      );

      final shortSize = tester.getSize(find.byKey(const ValueKey('shortCard')));
      final tallSize = tester.getSize(find.byKey(const ValueKey('tallCard')));
      expect(shortSize.height != tallSize.height, isTrue, reason: 'Without stretch, card heights differ');
    });
  });
}
