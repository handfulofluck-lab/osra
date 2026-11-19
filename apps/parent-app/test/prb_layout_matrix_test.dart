import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:familyshield_parent/api/models.dart';
import 'package:familyshield_parent/features/alerts/alerts_screen.dart';
import 'package:familyshield_parent/features/auth/login_screen.dart';
import 'package:familyshield_parent/features/children/child_detail_screen.dart';
import 'package:familyshield_parent/features/children/consent_screen.dart';
import 'package:familyshield_parent/features/dashboard/dashboard_screen.dart';
import 'package:familyshield_parent/features/map/family_map_screen.dart';
import 'package:familyshield_parent/features/onboarding/setup_child_screen.dart';
import 'package:familyshield_parent/features/onboarding/setup_done_screen.dart';
import 'package:familyshield_parent/features/onboarding/setup_monitoring_screen.dart';
import 'package:familyshield_parent/features/pairing/pair_qr_screen.dart';
import 'package:familyshield_parent/features/rules/rules_editor_screen.dart';
import 'package:familyshield_parent/features/settings/appearance_screen.dart';
import 'package:familyshield_parent/l10n/l10n.dart';
import 'package:familyshield_parent/providers/auth_provider.dart';
import 'package:familyshield_parent/providers/onboarding_provider.dart';
import 'package:familyshield_parent/providers/theme_provider.dart';
import 'package:familyshield_parent/providers/world_class_provider.dart';
import 'package:familyshield_parent/theme/app_theme.dart';
import 'package:familyshield_parent/widgets/layout_helpers.dart';

import 'fake_api_client.dart';

typedef _MatrixCase = ({
  Size size,
  double scale,
  Locale locale,
  Brightness brightness,
});

const List<Size> _kMatrixSizes = [
  Size(320, 568),
  Size(375, 667),
  Size(393, 852),
];

const List<double> _kMatrixScales = [1.0, 1.35, 2.0];

const List<Locale> _kMatrixLocales = [
  Locale('en'),
  Locale('ar'),
];

const List<Brightness> _kMatrixBrightnesses = [
  Brightness.light,
  Brightness.dark,
];

final List<_MatrixCase> _kFullMatrix = [
  for (final size in _kMatrixSizes)
    for (final scale in _kMatrixScales)
      for (final locale in _kMatrixLocales)
        for (final brightness in _kMatrixBrightnesses)
          (size: size, scale: scale, locale: locale, brightness: brightness),
];

final List<_MatrixCase> _kNarrowScale2Cases = [
  for (final locale in _kMatrixLocales)
    for (final brightness in _kMatrixBrightnesses)
      (
        size: const Size(320, 568),
        scale: 2.0,
        locale: locale,
        brightness: brightness,
      ),
];

String _caseLabel(_MatrixCase c) =>
    '${c.size.width.toInt()}x${c.size.height.toInt()} | '
    'scale ${c.scale} | ${c.locale.languageCode} | ${c.brightness.name}';

/// Locates the Flutter SDK's bundled Material Roboto fonts and loads them into
/// the test engine so `TextPainter` and `RenderParagraph` use real Roboto metrics.
Future<bool> _loadSdkRobotoFont() async {
  Directory? findMaterialFontsDir() {
    final sep = Platform.pathSeparator;
    for (final rel in ['test${sep}fonts', 'apps${sep}parent-app${sep}test${sep}fonts']) {
      final bundled = Directory(rel);
      if (bundled.existsSync()) return bundled;
    }
    final flutterRoot = Platform.environment['FLUTTER_ROOT'];
    if (flutterRoot != null && flutterRoot.isNotEmpty) {
      final dir = Directory(
        '$flutterRoot${sep}bin${sep}cache${sep}artifacts${sep}material_fonts',
      );
      if (dir.existsSync()) return dir;
    }
    var dir = File(Platform.resolvedExecutable).parent;
    for (var i = 0; i < 10; i++) {
      final candidate1 = Directory(
        '${dir.path}${sep}bin${sep}cache${sep}artifacts${sep}material_fonts',
      );
      if (candidate1.existsSync()) return candidate1;
      final candidate2 = Directory(
        '${dir.path}${sep}artifacts${sep}material_fonts',
      );
      if (candidate2.existsSync()) return candidate2;
      final candidate3 = Directory(
        '${dir.path}${sep}material_fonts',
      );
      if (candidate3.existsSync()) return candidate3;
      final parent = dir.parent;
      if (parent.path == dir.path) break;
      dir = parent;
    }
    return null;
  }

  final fontsDir = findMaterialFontsDir();
  if (fontsDir == null) return false;

  const files = [
    'roboto-regular.ttf',
    'roboto-medium.ttf',
    'roboto-bold.ttf',
  ];
  final loader = FontLoader('Roboto');
  var loadedCount = 0;
  for (final name in files) {
    final file = File('${fontsDir.path}${Platform.pathSeparator}$name');
    if (file.existsSync()) {
      final bytes = await file.readAsBytes();
      loader.addFont(Future.value(ByteData.sublistView(bytes)));
      loadedCount++;
    }
  }
  if (loadedCount != 3) return false;
  await loader.load();
  return true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    final hasRoboto = await _loadSdkRobotoFont();
    expect(hasRoboto, isTrue, reason: 'SDK Roboto font must load for layout metrics');
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

  void expectNoOverflow(WidgetTester tester, {String? contextLabel}) {
    final exceptions = drainExceptions(tester);
    expect(
      exceptions,
      isEmpty,
      reason: '${contextLabel ?? 'Screen'} threw layout/render exceptions:\n'
          '${exceptions.map((e) => e is FlutterError ? e.toStringDeep() : '$e').join('\n')}',
    );
  }

  Future<void> pumpMatrix(
    WidgetTester tester,
    Widget home, {
    required _MatrixCase matrix,
    FakeApiClient? api,
    List<Override> overrides = const [],
    bool settle = true,
    TargetPlatform? platformOverride,
  }) async {
    tester.view.physicalSize = matrix.size;
    tester.view.devicePixelRatio = 1.0;
    tester.platformDispatcher.platformBrightnessTestValue = matrix.brightness;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      tester.platformDispatcher.clearPlatformBrightnessTestValue();
    });

    final lightTheme = platformOverride == null
        ? AppTheme.light
        : AppTheme.light.copyWith(platform: platformOverride);
    final darkTheme = platformOverride == null
        ? AppTheme.dark
        : AppTheme.dark.copyWith(platform: platformOverride);

    final effectiveApi = api ?? FakeApiClient(standardRoutes());
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(effectiveApi),
          ...overrides,
        ],
        child: MaterialApp(
          locale: matrix.locale,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: lightTheme,
          darkTheme: darkTheme,
          themeMode: matrix.brightness == Brightness.dark
              ? ThemeMode.dark
              : ThemeMode.light,
          builder: (context, child) {
            final mq = MediaQuery.of(context);
            return MediaQuery(
              data: mq.copyWith(textScaler: TextScaler.linear(matrix.scale)),
              child: Directionality(
                textDirection: matrix.locale.languageCode == 'ar'
                    ? TextDirection.rtl
                    : TextDirection.ltr,
                child: child!,
              ),
            );
          },
          home: home,
        ),
      ),
    );

    if (settle) {
      await tester.pumpAndSettle();
    } else {
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
    }
  }

  void expectTextNotClipped(
    WidgetTester tester,
    Finder finder, {
    String? reason,
  }) {
    expect(finder, findsOneWidget, reason: reason);
    final element = tester.element(finder);
    final textWidget = tester.widget<Text>(finder);
    final renderObject = tester.renderObject(finder);
    final actualSize = tester.getSize(finder);
    if (renderObject is RenderParagraph) {
      expect(
        renderObject.didExceedMaxLines,
        isFalse,
        reason: '${reason ?? 'Text "${textWidget.data}"'} exceeded maxLines in RenderParagraph',
      );
    }
    final data = textWidget.data ?? textWidget.textSpan?.toPlainText() ?? '';
    final resolvedStyle = DefaultTextStyle.of(element).style.merge(textWidget.style);
    final painter = TextPainter(
      text: TextSpan(text: data, style: resolvedStyle),
      textDirection: Directionality.of(element),
      textScaler: MediaQuery.textScalerOf(element),
      maxLines: textWidget.maxLines,
    )..layout(maxWidth: actualSize.width);
    expect(
      painter.didExceedMaxLines,
      isFalse,
      reason: '${reason ?? 'Text "$data"'} exceeded maxLines (${textWidget.maxLines}) at width ${actualSize.width}',
    );
    expect(
      actualSize.height + 0.5,
      greaterThanOrEqualTo(painter.height),
      reason: '${reason ?? 'Text "$data"'} box height (${actualSize.height}) clipped full text height (${painter.height})',
    );
  }

  /// Asserts that no individual word in [text] was split mid-word across lines
  /// when laid out within [maxWidth].
  void expectNoMidWordBreak(
    WidgetTester tester,
    Finder finder, {
    String? reason,
  }) {
    expect(finder, findsOneWidget, reason: reason);
    final element = tester.element(finder);
    final textWidget = tester.widget<Text>(finder);
    final data = textWidget.data ?? '';
    final maxWidth = tester.getSize(finder).width;
    final resolvedStyle = DefaultTextStyle.of(element).style.merge(textWidget.style);
    final scaler = MediaQuery.textScalerOf(element);
    final dir = Directionality.of(element);

    final painter = TextPainter(
      text: TextSpan(text: data, style: resolvedStyle),
      textDirection: dir,
      textScaler: scaler,
      maxLines: textWidget.maxLines,
    )..layout(maxWidth: maxWidth);
    expect(painter.didExceedMaxLines, isFalse, reason: reason);

    // Every single whitespace-delimited word should fit on a single line within maxWidth.
    for (final word in data.split(RegExp(r'\s+')).where((w) => w.isNotEmpty)) {
      final wordPainter = TextPainter(
        text: TextSpan(text: word, style: resolvedStyle),
        textDirection: dir,
        textScaler: scaler,
        maxLines: 1,
      )..layout(maxWidth: maxWidth);
      expect(
        wordPainter.didExceedMaxLines,
        isFalse,
        reason: '${reason ?? 'Text "$data"'}: word "$word" broke mid-word at width $maxWidth',
      );
    }
  }

  group('1. Auth onboarding sign-in & MFA field (Item 4)', () {
    for (final matrix in _kFullMatrix) {
      testWidgets('LoginScreen(onboarding: true) [${_caseLabel(matrix)}]', (tester) async {
        SharedPreferences.setMockInitialValues({
          kOnboardingCompleteKey: false,
          kOnboardingStepKey: 'sign_in',
        });
        final l10n = lookupAppLocalizations(matrix.locale);
        await pumpMatrix(
          tester,
          const LoginScreen(onboarding: true),
          matrix: matrix,
        );

        expect(find.text(l10n.onboardingSignInTitle), findsOneWidget);
        expectTextNotClipped(
          tester,
          find.text(l10n.onboardingSignInTitle),
          reason: 'onboardingSignInTitle [${_caseLabel(matrix)}]',
        );

        final expectedMfaLabel = matrix.locale.languageCode == 'ar'
            ? 'رمز تطبيق المصادقة'
            : 'Authenticator code';
        final expectedMfaHelper = matrix.locale.languageCode == 'ar'
            ? 'مطلوب فقط إذا كان التحقق بخطوتين مفعّلًا في حسابك.'
            : 'Only if two-step verification is on for your account.';

        expect(l10n.mfaCodeLabel, expectedMfaLabel);
        expect(l10n.mfaCodeHelper, expectedMfaHelper);
        expect(find.text(expectedMfaLabel), findsOneWidget);
        expect(find.text(expectedMfaHelper), findsOneWidget);

        expectNoOverflow(tester, contextLabel: 'LoginScreen [${_caseLabel(matrix)}]');
      });
    }
  });

  group('2. Dashboard no-limit child, location message & live activity chip (Items 4 & 7)', () {
    FakeApiClient dashboardApi({
      bool includeDevice = false,
      bool refuseLocation = true,
    }) {
      final now = DateTime.now().toUtc();
      return FakeApiClient({
        ...standardRoutes(
          familyMe: {
            'family': {'id': 'fam-1', 'name': 'QA Family', 'region': 'US', 'createdAt': now.toIso8601String()},
            'parent': {
              'id': 'par-1',
              'familyId': 'fam-1',
              'email': 'qa@osratech.com',
              'displayName': 'QA Parent',
              'role': 'guardian',
              'mfaEnabled': false,
            },
            'children': [
              {
                'id': 'child-1',
                'familyId': 'fam-1',
                'displayName': 'Alex',
                'birthYear': 2013,
                'screenTimeTodayMinutes': 45,
              },
            ],
            'devices': includeDevice
                ? [
                    {
                      'id': 'dev-1',
                      'childId': 'child-1',
                      'platform': 'android',
                      'model': 'Pixel 7a',
                      'osVersion': '15',
                      'status': 'online',
                      'batteryPct': 55,
                      'lastSeen': now.toIso8601String(),
                    },
                  ]
                : const <Map<String, dynamic>>[],
          },
        ),
        'GET /v1/rules/child-1': (_) => {
              ...ruleSetPayload('child-1'),
              'screenTime': {
                'dailyLimitMinutes': 0,
                'weekendLimitMinutes': 0,
                'bedtimeStart': '21:00',
                'bedtimeEnd': '07:00',
                'schoolHours': {
                  'start': '08:00',
                  'end': '15:00',
                  'days': [1, 2, 3, 4, 5],
                },
              },
            },
        'GET /v1/location/child-1/latest': (_) => refuseLocation
            ? const FakeHttpError(
                403,
                {'error': 'permission_required', 'permission': 'location'},
              )
            : {'latest': null},
      });
    }

    for (final matrix in _kFullMatrix) {
      testWidgets('DashboardScreen no-limit child [${_caseLabel(matrix)}]', (tester) async {
        final l10n = lookupAppLocalizations(matrix.locale);
        final api = dashboardApi(includeDevice: true);
        await pumpMatrix(
          tester,
          const DashboardScreen(),
          matrix: matrix,
          api: api,
          overrides: [
            liveActivityProvider.overrideWith(
              (ref) => {
                'child-1': LiveActivity(
                  childId: 'child-1',
                  app: 'YouTube Kids Learning Videos',
                  minutesToday: 45,
                  ts: DateTime.now(),
                ),
              },
            ),
          ],
        );

        expect(find.text(l10n.readPermissionRequired), findsOneWidget);
        expect(find.byKey(const ValueKey('liveChip-child-1')), findsOneWidget);
        expect(find.textContaining('YouTube Kids Learning Videos'), findsOneWidget);

        final screenTimeFinder = find.text(l10n.minutesShort(45));
        expect(screenTimeFinder, findsOneWidget);
        final screenTimeText = tester.widget<Text>(screenTimeFinder).data!;
        expect(screenTimeText, isNot(contains('—')));
        expect(screenTimeText, isNot(contains('/')));

        expect(find.byType(LinearProgressIndicator), findsNothing);
        expectNoOverflow(tester, contextLabel: 'DashboardScreen [${_caseLabel(matrix)}]');
      });
    }

    for (final matrix in _kNarrowScale2Cases) {
      testWidgets('DashboardScreen no-limit + location refusal [${_caseLabel(matrix)}]', (tester) async {
        final l10n = lookupAppLocalizations(matrix.locale);
        await pumpMatrix(
          tester,
          const DashboardScreen(),
          matrix: matrix,
          api: dashboardApi(includeDevice: false, refuseLocation: true),
        );

        expect(find.text(l10n.readPermissionRequired), findsOneWidget);
        final screenTimeFinder = find.text(l10n.minutesShort(45));
        expect(screenTimeFinder, findsOneWidget);
        final screenTimeText = tester.widget<Text>(screenTimeFinder).data!;
        expect(screenTimeText, isNot(contains('—')));
        expect(screenTimeText, isNot(contains('/')));
        expect(find.byType(LinearProgressIndicator), findsNothing);
        expectNoOverflow(tester, contextLabel: 'DashboardScreen location [${_caseLabel(matrix)}]');
      });

      testWidgets('ChildCard combined no-limit + location + liveChip + device [${_caseLabel(matrix)}]', (tester) async {
        final l10n = lookupAppLocalizations(matrix.locale);
        const child = Child(
          id: 'child-1',
          familyId: 'fam-1',
          displayName: 'Alex',
          birthYear: 2013,
          screenTimeTodayMinutes: 45,
        );
        await pumpMatrix(
          tester,
          const Scaffold(
            body: Padding(
              padding: EdgeInsets.all(12),
              child: SizedBox(
                height: 460,
                child: ChildCard(child: child),
              ),
            ),
          ),
          matrix: matrix,
          api: dashboardApi(includeDevice: true, refuseLocation: true),
          overrides: [
            liveActivityProvider.overrideWith(
              (ref) => {
                'child-1': LiveActivity(
                  childId: 'child-1',
                  app: 'YouTube Kids Learning Videos',
                  minutesToday: 45,
                  ts: DateTime.now(),
                ),
              },
            ),
          ],
        );

        expect(find.text(l10n.readPermissionRequired), findsOneWidget);
        expect(find.byKey(const ValueKey('liveChip-child-1')), findsOneWidget);
        expect(find.textContaining('YouTube Kids Learning Videos'), findsOneWidget);
        final screenTimeFinder = find.text(l10n.minutesShort(45));
        expect(screenTimeFinder, findsOneWidget);
        final screenTimeText = tester.widget<Text>(screenTimeFinder).data!;
        expect(screenTimeText, isNot(contains('—')));
        expect(screenTimeText, isNot(contains('/')));
        expect(find.byType(LinearProgressIndicator), findsNothing);
        expectNoOverflow(tester, contextLabel: 'ChildCard combined [${_caseLabel(matrix)}]');
      });
    }
  });

  group('3. Alerts SOS detail dialog (Items 6, 8, 9)', () {
    FakeApiClient sosApi() {
      final now = DateTime.now().toUtc();
      return FakeApiClient({
        ...standardRoutes(
          alerts: [
            {
              'id': 'a-sos-1',
              'childId': 'child-1',
              'deviceId': 'dev-1',
              'severity': 'critical',
              'category': 'sos',
              'title': 'SOS pressed',
              'body': 'Your child pressed the SOS button and needs immediate attention from a parent.',
              'metadata': <String, dynamic>{
                'deviceId': 'dev-1',
                'lat': 25.2769,
                'lng': 51.5211,
                'accuracyM': 20,
                'takenAt': now.subtract(const Duration(minutes: 3)).toIso8601String(),
                'ageSeconds': 180,
              },
              'createdAt': now.toIso8601String(),
              'acknowledged': false,
            },
          ],
        ),
      });
    }

    for (final matrix in _kFullMatrix) {
      testWidgets('SOS detail dialog [${_caseLabel(matrix)}]', (tester) async {
        final l10n = lookupAppLocalizations(matrix.locale);
        await pumpMatrix(
          tester,
          const AlertsScreen(),
          matrix: matrix,
          api: sosApi(),
        );

        await tester.tap(find.byType(AlertTile).first);
        await tester.pumpAndSettle();

        final dialogFinder = find.byType(AlertDialog);
        expect(dialogFinder, findsOneWidget);
        expectNoOverflow(tester, contextLabel: 'SOS Dialog [${_caseLabel(matrix)}]');

        expect(find.byKey(const ValueKey('alert-technical-details')), findsNothing);

        final scrollableFinder = find.descendant(
          of: dialogFinder,
          matching: find.byType(SingleChildScrollView),
        );
        expect(scrollableFinder, findsOneWidget);
        final scrollableRect = tester.getRect(scrollableFinder);

        final showOnMapFinder = find.byKey(const ValueKey('alert-show-on-map'));
        final copyFinder = find.byKey(const ValueKey('alert-copy-coordinates'));
        final closeFinder = find.widgetWithText(TextButton, l10n.close);

        expect(showOnMapFinder, findsOneWidget);
        expect(copyFinder, findsOneWidget);
        expect(closeFinder, findsOneWidget);

        expect(
          tester.getSize(showOnMapFinder).height,
          greaterThanOrEqualTo(52.0),
          reason: 'Show on map button must be >= 52 dp tall',
        );

        final expectedCopyLabel = matrix.locale.languageCode == 'ar'
            ? 'نسخ الإحداثيات'
            : 'Copy coordinates';
        expect(l10n.alertCopyCoordinates, expectedCopyLabel);
        final copyTextFinder = find.descendant(
          of: copyFinder,
          matching: find.text(expectedCopyLabel),
        );
        expectTextNotClipped(tester, copyTextFinder, reason: 'Copy coordinates wrap');
        final copyRect = tester.getRect(copyFinder);
        expect(copyRect.left, greaterThanOrEqualTo(-0.5));
        expect(copyRect.right, lessThanOrEqualTo(matrix.size.width + 0.5));

        final locationFinder = find.byKey(const ValueKey('alert-sos-location'));
        expect(locationFinder, findsOneWidget);
        expect(
          find.descendant(
            of: dialogFinder,
            matching: find.text('Your child pressed the SOS button and needs immediate attention from a parent.'),
          ),
          findsNothing,
        );

        final locationRect = tester.getRect(locationFinder);

        for (final actionFinder in [showOnMapFinder, copyFinder, closeFinder]) {
          final actionRect = tester.getRect(actionFinder);
          expect(
            actionRect.top,
            greaterThanOrEqualTo(scrollableRect.top),
            reason: 'Action button top must be >= scrollable top',
          );
          expect(
            actionRect.top,
            greaterThanOrEqualTo(scrollableRect.bottom - 0.5),
            reason: 'Action buttons must sit BELOW dialog scrollable content',
          );
          final visibleLocationRect = locationRect.intersect(scrollableRect);
          expect(
            visibleLocationRect.overlaps(actionRect),
            isFalse,
            reason: 'alert-sos-location must not overlap action buttons',
          );
        }

        // Verify dialog content scrolls smoothly without overlap or overflow.
        await tester.drag(scrollableFinder, const Offset(0, -120));
        await tester.pumpAndSettle();
        expectNoOverflow(tester, contextLabel: 'SOS Dialog after scroll [${_caseLabel(matrix)}]');

        for (final actionFinder in [showOnMapFinder, copyFinder, closeFinder]) {
          final actionRect = tester.getRect(actionFinder);
          expect(actionRect.top, greaterThanOrEqualTo(scrollableRect.top));
        }
      });
    }

    for (final matrix in _kNarrowScale2Cases) {
      testWidgets('SOS detail dialog iOS Open in Maps >= 52dp [${_caseLabel(matrix)}]', (tester) async {
        final l10n = lookupAppLocalizations(matrix.locale);
        await pumpMatrix(
          tester,
          const AlertsScreen(),
          matrix: matrix,
          api: sosApi(),
          platformOverride: TargetPlatform.iOS,
        );

        await tester.tap(find.byType(AlertTile).first);
        await tester.pumpAndSettle();

        final openInMapsFinder = find.byKey(const ValueKey('alert-open-in-maps'));
        expect(openInMapsFinder, findsOneWidget);
        expect(find.text(l10n.alertOpenInMaps), findsOneWidget);
        expect(
          tester.getSize(openInMapsFinder).height,
          greaterThanOrEqualTo(52.0),
          reason: 'Open in Maps button must be >= 52 dp tall',
        );
        expectNoOverflow(tester, contextLabel: 'SOS Dialog iOS [${_caseLabel(matrix)}]');
      });
    }
  });

  group('4. Onboarding primary action buttons (Item 8)', () {
    void verifyPrimaryButton(
      WidgetTester tester, {
      required ValueKey<String> key,
      required String label,
      required _MatrixCase matrix,
    }) {
      final buttonFinder = find.byKey(key);
      expect(buttonFinder, findsOneWidget);
      final size = tester.getSize(buttonFinder);
      expect(
        size.height,
        greaterThanOrEqualTo(52.0),
        reason: '${key.value} height (${size.height}) must be >= 52.0 at ${_caseLabel(matrix)}',
      );
      final textFinder = find.descendant(of: buttonFinder, matching: find.text(label));
      expectTextNotClipped(tester, textFinder, reason: '${key.value} text');
      final textRect = tester.getRect(textFinder);
      final buttonRect = tester.getRect(buttonFinder);
      expect(
        textRect.top,
        greaterThanOrEqualTo(buttonRect.top - 0.5),
        reason: '${key.value} text clipped at top',
      );
      expect(
        textRect.bottom,
        lessThanOrEqualTo(buttonRect.bottom + 0.5),
        reason: '${key.value} text clipped at bottom',
      );
    }

    for (final matrix in _kNarrowScale2Cases) {
      testWidgets('SetupChildScreen onboardingAddChild [${_caseLabel(matrix)}]', (tester) async {
        final l10n = lookupAppLocalizations(matrix.locale);
        final api = FakeApiClient({
          ...standardRoutes(
            familyMe: {
              ...familyMeTwoChildren(),
              'children': <Map<String, dynamic>>[],
              'devices': <Map<String, dynamic>>[],
            },
          ),
        });
        await pumpMatrix(tester, const SetupChildScreen(), matrix: matrix, api: api);

        await tester.scrollUntilVisible(
          find.byKey(const ValueKey('onboardingAddChild')),
          200,
          scrollable: find
              .byWidgetPredicate((w) => w is Scrollable && w.axis == Axis.vertical)
              .first,
        );
        await tester.pumpAndSettle();

        verifyPrimaryButton(
          tester,
          key: const ValueKey('onboardingAddChild'),
          label: l10n.onboardingAddChildContinue,
          matrix: matrix,
        );
        expectNoOverflow(tester, contextLabel: 'SetupChildScreen [${_caseLabel(matrix)}]');
      });

      /// #874 (Arabic Language Bureau's frame at `49488d7e`): at AR 320 / 200 % the *selected* value of
      /// the consent-method field was cut — «رسالة نصية مع تأكيد» read as «رسالة نصية». Cause:
      /// `DropdownButtonFormField.isDense` defaults to true, which caps the inner box at
      /// kMinInteractiveDimension (48 px) while the wrapped label needs 96. The label must be laid out
      /// whole, not ellipsised and not clipped vertically.
      testWidgets('SetupChildScreen consent method label [${_caseLabel(matrix)}]', (tester) async {
        final l10n = lookupAppLocalizations(matrix.locale);
        final api = FakeApiClient({
          ...standardRoutes(
            familyMe: {
              ...familyMeTwoChildren(),
              'children': <Map<String, dynamic>>[],
              'devices': <Map<String, dynamic>>[],
            },
          ),
        });
        await pumpMatrix(tester, const SetupChildScreen(), matrix: matrix, api: api);

        final label = find.text(l10n.consentMethodSmsPlus);
        if (label.evaluate().isEmpty) {
          await tester.scrollUntilVisible(
            label,
            200,
            scrollable: find
                .byWidgetPredicate((w) => w is Scrollable && w.axis == Axis.vertical)
                .first,
          );
          await tester.pumpAndSettle();
        }
        expectTextNotClipped(tester, label, reason: 'consent method selected value (#874)');
      });

      testWidgets('PairingQrScreen onboardingPairDone [${_caseLabel(matrix)}]', (tester) async {
        final l10n = lookupAppLocalizations(matrix.locale);
        final api = FakeApiClient({
          ...standardRoutes(
            familyMe: {
              ...familyMeTwoChildren(),
              'devices': <Map<String, dynamic>>[],
            },
          ),
        });
        await pumpMatrix(
          tester,
          const PairingQrScreen(
            onboarding: true,
            childId: 'child-1',
            childName: 'Alex',
          ),
          matrix: matrix,
          api: api,
          settle: false,
        );

        await tester.scrollUntilVisible(
          find.byKey(const ValueKey('onboardingPairDone')),
          200,
          scrollable: find
              .byWidgetPredicate((w) => w is Scrollable && w.axis == Axis.vertical)
              .first,
        );
        await tester.pump();

        verifyPrimaryButton(
          tester,
          key: const ValueKey('onboardingPairDone'),
          label: l10n.onboardingPairConfirm,
          matrix: matrix,
        );
        expectNoOverflow(tester, contextLabel: 'PairingQrScreen [${_caseLabel(matrix)}]');

        // Cancel live countdown / claim timers cleanly.
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
      });

      testWidgets('SetupDoneScreen onboardingFinish [${_caseLabel(matrix)}]', (tester) async {
        final l10n = lookupAppLocalizations(matrix.locale);
        await pumpMatrix(tester, const SetupDoneScreen(), matrix: matrix);

        verifyPrimaryButton(
          tester,
          key: const ValueKey('onboardingFinish'),
          label: l10n.onboardingGoToDashboard,
          matrix: matrix,
        );
        expectNoOverflow(tester, contextLabel: 'SetupDoneScreen [${_caseLabel(matrix)}]');
      });

      testWidgets('SetupMonitoringScreen setupMonitoringContinue [${_caseLabel(matrix)}]', (tester) async {
        final l10n = lookupAppLocalizations(matrix.locale);
        await pumpMatrix(
          tester,
          const SetupMonitoringScreen(childId: 'child-1'),
          matrix: matrix,
        );

        verifyPrimaryButton(
          tester,
          key: const ValueKey('setupMonitoringContinue'),
          label: l10n.setupMonitoringContinue,
          matrix: matrix,
        );
        expectNoOverflow(tester, contextLabel: 'SetupMonitoringScreen [${_caseLabel(matrix)}]');
      });
    }
  });

  group('5a. Appearance theme selector (Items 4 & 10)', () {
    for (final matrix in _kNarrowScale2Cases) {
      testWidgets('AppearanceScreen stacks vertically and switches to Dark [${_caseLabel(matrix)}]', (tester) async {
        final l10n = lookupAppLocalizations(matrix.locale);
        late WidgetRef capturedRef;
        await pumpMatrix(
          tester,
          Consumer(builder: (context, ref, _) {
            capturedRef = ref;
            return const AppearanceScreen();
          }),
          matrix: matrix,
        );

        final selectorFinder = find.byKey(const ValueKey('themeModeSelector'));
        expect(selectorFinder, findsOneWidget);
        expect(tester.widget(selectorFinder), isA<Column>());
        expect(find.byType(SegmentedButton<ThemeMode>), findsNothing);

        for (final label in [l10n.system, l10n.light, l10n.dark]) {
          final textFinder = find.descendant(
            of: selectorFinder,
            matching: find.text(label),
          );
          expectNoMidWordBreak(tester, textFinder, reason: 'Appearance option "$label"');
        }

        final darkLabel = matrix.locale.languageCode == 'ar' ? 'داكن' : 'Dark';
        expect(l10n.dark, darkLabel);
        await tester.tap(find.descendant(of: selectorFinder, matching: find.text(darkLabel)));
        await tester.pumpAndSettle();

        expect(capturedRef.read(themeModeProvider), ThemeMode.dark);
        expectNoOverflow(tester, contextLabel: 'AppearanceScreen [${_caseLabel(matrix)}]');
      });
    }

    for (final locale in _kMatrixLocales) {
      testWidgets('AppearanceScreen keeps SegmentedButton at 393x852 scale 1.0 (${locale.languageCode})', (tester) async {
        const matrix = (
          size: Size(393, 852),
          scale: 1.0,
          locale: Locale('en'),
          brightness: Brightness.light,
        );
        await pumpMatrix(
          tester,
          const AppearanceScreen(),
          matrix: (
            size: matrix.size,
            scale: matrix.scale,
            locale: locale,
            brightness: matrix.brightness,
          ),
        );

        final selectorFinder = find.byKey(const ValueKey('themeModeSelector'));
        expect(selectorFinder, findsOneWidget);
        expect(tester.widget(selectorFinder), isA<SegmentedButton<ThemeMode>>());
        expectNoOverflow(tester, contextLabel: 'AppearanceScreen 393x852 ${locale.languageCode}');
      });
    }
  });

  group('5b. Consent details & revoke button (Items 7, 8, 9)', () {
    for (final matrix in _kNarrowScale2Cases) {
      testWidgets('ConsentScreen LabelValueRow & consentRevokeButton [${_caseLabel(matrix)}]', (tester) async {
        final l10n = lookupAppLocalizations(matrix.locale);
        await pumpMatrix(
          tester,
          const ConsentScreen(childId: 'child-1'),
          matrix: matrix,
        );

        for (final label in [
          l10n.consentMethodLabel,
          l10n.consentJurisdictionLabel,
          l10n.consentGrantedLabel,
          l10n.consentExpiryLabel,
          l10n.consentThirdPartyLabel,
          l10n.consentRevokedLabel,
        ]) {
          final labelFinder = find.descendant(
            of: find.byType(LabelValueRow),
            matching: find.text(label),
          );
          if (labelFinder.evaluate().isNotEmpty) {
            expectNoMidWordBreak(tester, labelFinder, reason: 'Consent label "$label"');
          }
        }

        final expectedSmsPlus = matrix.locale.languageCode == 'ar'
            ? 'رسالة نصية مع تأكيد'
            : 'Text message plus confirmation';
        expect(l10n.consentMethodSmsPlus, expectedSmsPlus);
        expect(find.text(expectedSmsPlus), findsOneWidget);

        final revokeFinder = find.byKey(const ValueKey('consentRevokeButton'));
        await tester.scrollUntilVisible(revokeFinder, 200);
        await tester.pumpAndSettle();

        expect(revokeFinder, findsOneWidget);
        expect(
          tester.getSize(revokeFinder).height,
          greaterThanOrEqualTo(52.0),
          reason: 'consentRevokeButton must be >= 52 dp tall',
        );
        expectNoOverflow(tester, contextLabel: 'ConsentScreen [${_caseLabel(matrix)}]');
      });
    }
  });

  group('5c. Rules editor heading, tabs, timeTile & slider semantics (Items 4, 7, 9, 11)', () {
    for (final matrix in _kNarrowScale2Cases) {
      testWidgets('RulesEditorScreen [${_caseLabel(matrix)}]', (tester) async {
        final semantics = tester.ensureSemantics();
        try {
          final l10n = lookupAppLocalizations(matrix.locale);
          await pumpMatrix(
            tester,
            const RulesEditorScreen(childId: 'child-1'),
            matrix: matrix,
          );

          final titleFinder = find.text(l10n.editRules);
          expect(titleFinder, findsOneWidget);
          expectTextNotClipped(tester, titleFinder, reason: 'RulesEditor editRules title');
          final titleInAppBar = find.descendant(
            of: find.byType(AppBar),
            matching: find.text(l10n.editRules),
          );
          final appBarWidget = tester.widget<AppBar>(find.byType(AppBar));
          if (titleInAppBar.evaluate().isEmpty) {
            expect(
              appBarWidget.toolbarHeight,
              lessThan(matrix.scale * (kToolbarHeight + 8.0)),
              reason: 'Collapsed AppBar toolbarHeight should stay compact for Save only',
            );
          }
          final saveFinder = find.descendant(
            of: find.byType(AppBar),
            matching: find.text(l10n.save),
          );
          expectTextNotClipped(tester, saveFinder, reason: 'RulesEditor Save label');

          final fadingTabBarFinder = find.byType(FadingScrollableTabBar);
          expect(fadingTabBarFinder, findsOneWidget);
          final tabBarFinder = find.descendant(
            of: fadingTabBarFinder,
            matching: find.byType(TabBar),
          );
          expect(tabBarFinder, findsOneWidget);
          expect(tester.widget<TabBar>(tabBarFinder).isScrollable, isTrue);
          expect(
            find.descendant(of: fadingTabBarFinder, matching: find.byType(ShaderMask)),
            findsOneWidget,
          );

          // Both limit Sliders expose localized semanticValue via semanticFormatterCallback & Semantics.
          String? firstNonEmptySemanticValue(SemanticsNode node) {
            if (node.value.isNotEmpty) return node.value;
            String? found;
            node.visitChildren((child) {
              found ??= firstNonEmptySemanticValue(child);
              return found == null;
            });
            return found;
          }

          final sliderFinder = find.byType(Slider);
          expect(sliderFinder, findsNWidgets(2));
          final dailySlider = tester.widget<Slider>(sliderFinder.at(0));
          final weekendSlider = tester.widget<Slider>(sliderFinder.at(1));
          expect(dailySlider.semanticFormatterCallback?.call(120), l10n.minutesShort(120));
          expect(weekendSlider.semanticFormatterCallback?.call(240), l10n.minutesShort(240));
          expect(
            firstNonEmptySemanticValue(tester.getSemantics(sliderFinder.at(0))),
            l10n.minutesShort(120),
          );
          expect(
            firstNonEmptySemanticValue(tester.getSemantics(sliderFinder.at(1))),
            l10n.minutesShort(240),
          );

          // Scroll to timeTile rows (Bedtime / School hours Starts & Ends).
          await tester.scrollUntilVisible(
            find.text(l10n.starts),
            150,
            scrollable: find
                .descendant(
                  of: find.byType(TabBarView),
                  matching: find.byWidgetPredicate((w) => w is Scrollable && w.axis == Axis.vertical),
                )
                .first,
          );
          await tester.pumpAndSettle();

          final labelValueRows = find.byType(LabelValueRow);
          expect(labelValueRows, findsWidgets);
          for (final label in [l10n.starts, l10n.ends]) {
            final labelFinder = find.descendant(
              of: labelValueRows,
              matching: find.text(label),
            );
            if (labelFinder.evaluate().isNotEmpty) {
              expectNoMidWordBreak(tester, labelFinder.first, reason: 'timeTile label "$label"');
            }
          }

          // Verify label and value inside first LabelValueRow do not overlap.
          final firstRow = labelValueRows.first;
          final rowTexts = find.descendant(of: firstRow, matching: find.byType(Text));
          expect(rowTexts, findsNWidgets(2));
          final labelRect = tester.getRect(rowTexts.at(0));
          final valueRect = tester.getRect(rowTexts.at(1));
          expect(labelRect.overlaps(valueRect), isFalse, reason: 'timeTile label and value must not overlap');

          expectNoOverflow(tester, contextLabel: 'RulesEditorScreen [${_caseLabel(matrix)}]');
        } finally {
          semantics.dispose();
        }
      });
    }
  });

  group('5d. Child detail platform label, PhoneSetupSection pills, AlertTile & tabs (Items 4, 7, 9)', () {
    FakeApiClient childDetailApi() {
      final now = DateTime.now().toUtc();
      return FakeApiClient({
        ...standardRoutes(
          familyMe: {
            'family': {'id': 'fam-1', 'name': 'QA Family', 'region': 'US', 'createdAt': now.toIso8601String()},
            'parent': {
              'id': 'par-1',
              'familyId': 'fam-1',
              'email': 'qa@osratech.com',
              'displayName': 'QA Parent',
              'role': 'owner',
              'mfaEnabled': false,
            },
            'children': [
              {
                'id': 'child-1',
                'familyId': 'fam-1',
                'displayName': 'Alex',
                'birthYear': 2013,
                'screenTimeTodayMinutes': 45,
              },
            ],
            'devices': [
              {
                'id': 'dev-1',
                'childId': 'child-1',
                'platform': 'android',
                'model': 'Pixel 9',
                'osVersion': '16',
                'status': 'online',
                'batteryPct': 80,
                'lastSeen': now.toIso8601String(),
                'setup': {
                  'reportedAt': now.toIso8601String(),
                  'stale': false,
                  'features': {
                    'lock_screen': 'ready',
                    'pause_screen': 'ready',
                    'app_blocking': 'degraded',
                    'notification_scan': 'not_supported',
                    'call_sms_log': 'unavailable',
                  },
                  'missing': const ['accessibility'],
                },
              },
              {
                'id': 'dev-2',
                'childId': 'child-1',
                'platform': 'ios',
                'model': 'iPhone 16',
                'osVersion': '18',
                'status': 'online',
                'batteryPct': 72,
                'lastSeen': now.toIso8601String(),
              },
            ],
          },
          alerts: [
            {
              'id': 'a-long-1',
              'childId': 'child-1',
              'deviceId': 'dev-1',
              'severity': 'warning',
              'category': 'unmapped_custom',
              'title': 'Very long safety alert title that should wrap cleanly across two lines on narrow viewports',
              'body': 'Alert body',
              'metadata': <String, dynamic>{},
              'createdAt': now.toIso8601String(),
              'acknowledged': false,
            },
          ],
        ),
      });
    }

    for (final matrix in _kNarrowScale2Cases) {
      testWidgets('ChildDetailScreen [${_caseLabel(matrix)}]', (tester) async {
        final l10n = lookupAppLocalizations(matrix.locale);
        await pumpMatrix(
          tester,
          const ChildDetailScreen(childId: 'child-1'),
          matrix: matrix,
          api: childDetailApi(),
        );

        expect(formatDevicePlatformLabel('android', '16'), 'Android 16');
        expect(formatDevicePlatformLabel('ios', '18'), 'iPhone 18');
        expect(formatDevicePlatformLabel('', '16'), '16');
        expect(formatDevicePlatformLabel('  ', ''), '');
        expect(formatDevicePlatformLabel('android', ''), 'Android');
        expect(formatDevicePlatformLabel('ios', ''), 'iPhone');
        expect(find.text('Device'), findsNothing);
        expect(find.textContaining('Device ·'), findsNothing);

        final fadingTabBarFinder = find.byType(FadingScrollableTabBar);
        expect(fadingTabBarFinder, findsOneWidget);
        expect(
          find.descendant(of: fadingTabBarFinder, matching: find.byType(ShaderMask)),
          findsOneWidget,
        );

        expect(find.textContaining('Android 16'), findsOneWidget);

        final verticalScrollable = find
            .descendant(
              of: find.byType(TabBarView),
              matching: find.byWidgetPredicate((w) => w is Scrollable && w.axis == Axis.vertical),
            )
            .first;

        final setupSection = find.byKey(const ValueKey('phoneSetupSection'));
        await tester.scrollUntilVisible(setupSection, 150, scrollable: verticalScrollable);
        await tester.pumpAndSettle();

        final wrapFinder = find.descendant(
          of: setupSection,
          matching: find.byType(Wrap),
        );
        expect(wrapFinder, findsOneWidget);
        final pillContainers = find.descendant(
          of: wrapFinder,
          matching: find.byType(Container),
        );
        expect(pillContainers, findsWidgets);
        final viewportWidth = matrix.size.width;
        for (final element in pillContainers.evaluate()) {
          final box = element.renderObject! as RenderBox;
          final rect = box.localToGlobal(Offset.zero) & box.size;
          expect(rect.left, greaterThanOrEqualTo(-0.5));
          expect(
            rect.right,
            lessThanOrEqualTo(viewportWidth + 0.5),
            reason: 'PhoneSetupSection pill clipped trailing edge (${rect.right} > $viewportWidth)',
          );
        }

        // Scroll to the second device card to verify iPhone 18 label.
        await tester.scrollUntilVisible(
          find.textContaining('iPhone 18'),
          200,
          scrollable: verticalScrollable,
        );
        await tester.pumpAndSettle();
        expect(find.textContaining('iPhone 18'), findsOneWidget);

        // Switch to Alerts tab and verify AlertTile allows maxLines == 2.
        final alertsTabFinder = find.text(l10n.tabAlerts);
        await tester.ensureVisible(alertsTabFinder);
        await tester.pumpAndSettle();
        await tester.tap(alertsTabFinder);
        await tester.pumpAndSettle();

        final alertTileFinder = find.byType(AlertTile);
        expect(alertTileFinder, findsOneWidget);
        final listTile = tester.widget<ListTile>(
          find.descendant(of: alertTileFinder, matching: find.byType(ListTile)),
        );
        final titleText = listTile.title! as Text;
        expect(titleText.maxLines, 2);

        expectNoOverflow(tester, contextLabel: 'ChildDetailScreen [${_caseLabel(matrix)}]');
      });
    }

    testWidgets('ChildDetailScreen omits empty platform without Device fallback or leading separator', (tester) async {
      final now = DateTime.now().toUtc();
      for (final locale in _kMatrixLocales) {
        final l10n = lookupAppLocalizations(locale);
        final api = FakeApiClient({
          ...standardRoutes(
            familyMe: {
              'parent': {'id': 'p-1', 'email': 'parent@example.com', 'role': 'owner', 'mfaEnabled': false},
              'children': [
                {'id': 'child-1', 'familyId': 'fam-1', 'displayName': 'Alex', 'birthYear': 2013, 'screenTimeTodayMinutes': 45},
              ],
              'devices': [
                {
                  'id': 'dev-blank',
                  'childId': 'child-1',
                  'platform': '',
                  'model': 'Mystery Phone',
                  'osVersion': '',
                  'status': 'online',
                  'batteryPct': 50,
                  'lastSeen': now.toIso8601String(),
                },
              ],
            },
          ),
        });
        await pumpMatrix(
          tester,
          const ChildDetailScreen(childId: 'child-1'),
          matrix: (size: const Size(320, 568), scale: 1.0, locale: locale, brightness: Brightness.light),
          api: api,
        );
        final deviceCard = find.ancestor(
          of: find.text('Mystery Phone'),
          matching: find.byType(Card),
        );
        expect(deviceCard, findsOneWidget);
        expect(find.descendant(of: deviceCard, matching: find.textContaining('Device')), findsNothing);
        expect(find.descendant(of: deviceCard, matching: find.text(l10n.statusOnline)), findsOneWidget);
        expect(find.descendant(of: deviceCard, matching: find.textContaining('· ${l10n.statusOnline}')), findsNothing);
        expectNoOverflow(tester, contextLabel: 'ChildDetailScreen blank platform ${locale.languageCode}');
      }
    });
  });

  group('6. UI/UX Bureau B1-B4 & B7 at 310% max accessibility scale (320x568)', () {
    final maxScaleCases = [
      for (final locale in _kMatrixLocales)
        (
          size: const Size(320, 568),
          scale: 3.1,
          locale: locale,
          brightness: Brightness.light,
        ),
    ];

    FakeApiClient bureauApi({
      required Locale locale,
      int unreadAlerts = 0,
      int childCount = 1,
      List<String>? blockedCategories,
    }) {
      final now = DateTime.now().toUtc();
      final longName = locale.languageCode == 'ar'
          ? 'محمد مصطفى كاظم العلي'
          : 'Mohammed Mustafa Abdullah Al-Mansoor';
      final children = [
        for (var i = 0; i < childCount; i++)
          {
            'id': 'child-${i + 1}',
            'familyId': 'fam-1',
            'displayName': i == 0 ? longName : 'Nadia $i',
            'birthYear': 2013,
            'screenTimeTodayMinutes': 45,
          },
      ];
      final alerts = [
        for (var i = 0; i < unreadAlerts; i++)
          {
            'id': 'a-$i',
            'childId': 'child-1',
            'severity': 'warning',
            'category': 'tamper',
            'title': 'Alert $i',
            'body': 'Alert body $i',
            'metadata': <String, dynamic>{},
            'createdAt': now.toIso8601String(),
            'acknowledged': false,
          },
      ];
      return FakeApiClient({
        ...standardRoutes(
          familyMe: {
            'family': {
              'id': 'fam-1',
              'name': 'QA Family',
              'region': 'US',
              'createdAt': now.toIso8601String(),
            },
            'parent': {
              'id': 'par-1',
              'familyId': 'fam-1',
              'email': 'qa@osratech.com',
              'displayName': 'QA Parent',
              'role': 'owner',
              'mfaEnabled': false,
            },
            'children': children,
            'devices': [
              {
                'id': 'dev-1',
                'childId': 'child-1',
                'platform': 'android',
                'model': 'Pixel 9',
                'osVersion': '16',
                'status': 'online',
                'batteryPct': 80,
                'lastSeen': now.toIso8601String(),
              },
            ],
          },
          alerts: alerts,
          blockedCategories: blockedCategories,
        ),
        'GET /v1/alerts': (_) => {
              'items': alerts,
              'meta': {'total': unreadAlerts, 'page': 1, 'limit': 1},
            },
      });
    }

    for (final matrix in maxScaleCases) {
      testWidgets('B1 Pause internet confirm dialog scrolls with reachable buttons [${_caseLabel(matrix)}]', (tester) async {
        final l10n = lookupAppLocalizations(matrix.locale);
        await pumpMatrix(
          tester,
          const DashboardScreen(),
          matrix: matrix,
          api: bureauApi(locale: matrix.locale),
        );

        final pillFinder = find.byType(InternetPill).first;
        await tester.scrollUntilVisible(pillFinder, 120);
        await tester.pumpAndSettle();
        await tester.tap(pillFinder);
        await tester.pumpAndSettle();

        final dialogFinder = find.byType(AlertDialog);
        expect(dialogFinder, findsOneWidget);
        expect(tester.widget<AlertDialog>(dialogFinder).scrollable, isTrue);
        expect(
          find.descendant(of: dialogFinder, matching: find.byType(SingleChildScrollView)),
          findsOneWidget,
        );

        final cancelFinder = find.widgetWithText(TextButton, l10n.cancel);
        final pauseFinder = find.widgetWithText(FilledButton, l10n.pause);
        expect(cancelFinder, findsOneWidget);
        expect(pauseFinder, findsOneWidget);

        for (final btn in [cancelFinder, pauseFinder]) {
          final rect = tester.getRect(btn);
          expect(rect.top, greaterThanOrEqualTo(0));
          expect(
            rect.bottom,
            lessThanOrEqualTo(matrix.size.height),
            reason: 'B1 action button pushed off-screen ($rect)',
          );
        }

        expectNoOverflow(tester, contextLabel: 'B1 Pause confirm dialog [${_caseLabel(matrix)}]');

        await tester.tap(cancelFinder);
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
      });

      testWidgets('B2 card name unlimited & B3 bell badge capped at 1.3x at 3.1x [${_caseLabel(matrix)}]', (tester) async {
        final expectedName = matrix.locale.languageCode == 'ar'
            ? 'محمد مصطفى كاظم العلي'
            : 'Mohammed Mustafa Abdullah Al-Mansoor';
        await pumpMatrix(
          tester,
          const DashboardScreen(),
          matrix: matrix,
          api: bureauApi(locale: matrix.locale, unreadAlerts: 12),
        );

        // B2: card child name has no line limit or ellipsis.
        final nameFinder = find.descendant(
          of: find.byType(Card).first,
          matching: find.text(expectedName),
        );
        expect(nameFinder, findsOneWidget);
        final nameWidget = tester.widget<Text>(nameFinder);
        expect(nameWidget.maxLines, isNull);
        expect(nameWidget.overflow, isNull);

        // B3: bell Badge follows accessibility text scale up to 1.3x and never overlaps adjacent AppBar icons.
        final badgeFinder = find.byType(Badge);
        expect(badgeFinder, findsOneWidget);
        final badgeLabelFinder = find.descendant(
          of: badgeFinder,
          matching: find.text('12'),
        );
        expect(badgeLabelFinder, findsOneWidget);
        final badgeScaler = MediaQuery.textScalerOf(tester.element(badgeLabelFinder));
        expect(badgeScaler.scale(10.0), closeTo(13.0, 0.01));
        final labelSize = tester.getSize(badgeLabelFinder);
        expect(
          labelSize.height,
          lessThanOrEqualTo(24.0),
          reason: 'Badge count text scaled unexpectedly (${labelSize.height})',
        );
        final badgeRect = tester.getRect(badgeFinder);
        final mapBtnRect = tester.getRect(find.byIcon(Icons.map_outlined));
        final signOutBtnRect = tester.getRect(find.byIcon(Icons.logout));
        expect(badgeRect.overlaps(mapBtnRect), isFalse);
        expect(badgeRect.overlaps(signOutBtnRect), isFalse);

        expectNoOverflow(tester, contextLabel: 'B2/B3 Dashboard [${_caseLabel(matrix)}]');
      });

      testWidgets('B7 Dashboard scrolled to bottom clears Add Child FAB [${_caseLabel(matrix)}]', (tester) async {
        await pumpMatrix(
          tester,
          const DashboardScreen(),
          matrix: matrix,
          api: bureauApi(locale: matrix.locale, childCount: 3),
        );

        final scrollable = find.byWidgetPredicate(
          (w) => w is Scrollable && w.axis == Axis.vertical,
        ).first;
        await tester.drag(scrollable, const Offset(0, -1500));
        await tester.pumpAndSettle();

        final fabFinder = find.byType(FloatingActionButton);
        expect(fabFinder, findsOneWidget);
        final fabRect = tester.getRect(fabFinder);
        final lastCardRect = tester.getRect(find.byType(Card).last);
        expect(
          lastCardRect.bottom,
          lessThanOrEqualTo(fabRect.top + 0.5),
          reason: 'Last card (${lastCardRect.bottom}) did not clear FAB (${fabRect.top})',
        );
        expectNoOverflow(tester, contextLabel: 'B7 Dashboard end scroll [${_caseLabel(matrix)}]');
      });

      testWidgets('B4 ChildDetail & RulesEditor tabs scale height cleanly at 3.1x [${_caseLabel(matrix)}]', (tester) async {
        final l10n = lookupAppLocalizations(matrix.locale);
        await pumpMatrix(
          tester,
          const ChildDetailScreen(childId: 'child-1'),
          matrix: matrix,
          api: bureauApi(locale: matrix.locale),
        );

        final fadingBar = find.byType(FadingScrollableTabBar);
        expect(fadingBar, findsOneWidget);
        final fadingWidget = tester.widget<FadingScrollableTabBar>(fadingBar);
        expect(
          fadingWidget.preferredSize.height,
          greaterThan(54.0),
          reason: 'ChildDetail tab bar height (${fadingWidget.preferredSize.height}) must scale with 3.1x text',
        );
        final barRect = tester.getRect(fadingBar);
        final overviewTextRect = tester.getRect(find.text(l10n.tabOverview));
        expect(overviewTextRect.top, greaterThanOrEqualTo(barRect.top - 0.5));
        expect(overviewTextRect.bottom, lessThanOrEqualTo(barRect.bottom + 0.5));
        expectNoOverflow(tester, contextLabel: 'B4 ChildDetail tabs [${_caseLabel(matrix)}]');

        await pumpMatrix(
          tester,
          const RulesEditorScreen(childId: 'child-1'),
          matrix: matrix,
          api: bureauApi(locale: matrix.locale),
        );
        final rulesBar = find.byType(FadingScrollableTabBar);
        expect(rulesBar, findsOneWidget);
        final rulesWidget = tester.widget<FadingScrollableTabBar>(rulesBar);
        expect(rulesWidget.preferredSize.height, greaterThan(54.0));
        final rulesBarRect = tester.getRect(rulesBar);
        final screenTimeTabRect = tester.getRect(find.text(l10n.tabScreenTime));
        expect(screenTimeTabRect.top, greaterThanOrEqualTo(rulesBarRect.top - 0.5));
        expect(screenTimeTabRect.bottom, lessThanOrEqualTo(rulesBarRect.bottom + 0.5));
        expectNoOverflow(tester, contextLabel: 'B4 RulesEditor tabs [${_caseLabel(matrix)}]');
      });

      testWidgets('B1 SetupChild leave & RulesEditor disable-recommended confirm dialogs [${_caseLabel(matrix)}]', (tester) async {
        final l10n = lookupAppLocalizations(matrix.locale);
        // SetupChild leave confirm dialog.
        await pumpMatrix(
          tester,
          const SetupChildScreen(),
          matrix: matrix,
          api: bureauApi(locale: matrix.locale),
        );
        await tester.tap(find.byType(BackButton));
        await tester.pumpAndSettle();
        final leaveDialog = find.byType(AlertDialog);
        expect(leaveDialog, findsOneWidget);
        expect(tester.widget<AlertDialog>(leaveDialog).scrollable, isTrue);
        expect(
          tester.getRect(find.widgetWithText(FilledButton, l10n.onboardingLeaveConfirm)).bottom,
          lessThanOrEqualTo(matrix.size.height),
        );
        expectNoOverflow(tester, contextLabel: 'B1 SetupChild leave dialog [${_caseLabel(matrix)}]');
        await tester.tap(find.widgetWithText(TextButton, l10n.onboardingLeaveStay));
        await tester.pumpAndSettle();

        // RulesEditor disable-recommended confirm dialog & collapsed AppBar fallback height.
        await pumpMatrix(
          tester,
          const RulesEditorScreen(childId: 'child-1'),
          matrix: matrix,
          api: bureauApi(
            locale: matrix.locale,
            blockedCategories: kRecommendedCategories,
          ),
        );
        expect(
          find.descendant(of: find.byType(AppBar), matching: find.text(l10n.editRules)),
          findsNothing,
        );
        final appBarWidget = tester.widget<AppBar>(find.byType(AppBar));
        expect(
          appBarWidget.toolbarHeight,
          allOf(isNotNull, greaterThan(kToolbarHeight), lessThan(100.0)),
          reason: 'Collapsed AppBar toolbarHeight at 3.1x must fit Save without bloating to title height',
        );
        final saveLabelFinder = find.descendant(
          of: find.byType(AppBar),
          matching: find.text(l10n.save),
        );
        expectTextNotClipped(tester, saveLabelFinder, reason: 'RulesEditor Save label at 3.1x');
        final toolbarRect = tester.getRect(
          find.descendant(of: find.byType(AppBar), matching: find.byType(NavigationToolbar)),
        );
        final saveRect = tester.getRect(saveLabelFinder);
        expect(saveRect.top, greaterThanOrEqualTo(toolbarRect.top - 0.5));
        expect(saveRect.bottom, lessThanOrEqualTo(toolbarRect.bottom + 0.5));

        final webFilterTab = find.text(l10n.tabWebFilter);
        await tester.ensureVisible(webFilterTab);
        await tester.pumpAndSettle();
        await tester.tap(webFilterTab);
        await tester.pumpAndSettle();
        final recSwitch = find.descendant(
          of: find.widgetWithText(SwitchListTile, l10n.recommendedProtection),
          matching: find.byType(Switch),
        );
        await tester.ensureVisible(recSwitch);
        await tester.pumpAndSettle();
        await tester.tap(recSwitch);
        await tester.pumpAndSettle();

        final recDialog = find.byType(AlertDialog);
        expect(recDialog, findsOneWidget);
        expect(tester.widget<AlertDialog>(recDialog).scrollable, isTrue);
        expect(find.text(l10n.disablingRecommended), findsOneWidget);
        expect(
          tester.getRect(find.widgetWithText(FilledButton, l10n.continueLabel)).bottom,
          lessThanOrEqualTo(matrix.size.height),
        );
        expectNoOverflow(tester, contextLabel: 'B1 RulesEditor disable-recommended dialog [${_caseLabel(matrix)}]');
        await tester.tap(find.widgetWithText(TextButton, l10n.cancel));
        await tester.pumpAndSettle();
      });

      testWidgets('ChildMapSheet wraps Ring/Lock and scrolls inside modal bottom sheet [${_caseLabel(matrix)}]', (tester) async {
        final l10n = lookupAppLocalizations(matrix.locale);
        final now = DateTime.now().toUtc();
        final child = Child(
          id: 'child-1',
          familyId: 'fam-1',
          displayName: matrix.locale.languageCode == 'ar' ? 'ليلى' : 'Layla',
          birthYear: 2014,
          screenTimeTodayMinutes: 30,
        );
        final device = Device(
          id: 'dev-1',
          childId: 'child-1',
          platform: 'android',
          model: 'Pixel 9',
          osVersion: '16',
          status: 'online',
          batteryPct: 80,
          lastSeen: now,
        );
        final ping = LocationPing(
          deviceId: 'dev-1',
          lat: 25.276900,
          lng: 51.521100,
          timestamp: now,
        );

        await pumpMatrix(
          tester,
          Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: FilledButton(
                  onPressed: () => showChildMapSheet(
                    context,
                    child: child,
                    ping: ping,
                    device: device,
                  ),
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
          matrix: matrix,
        );

        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();

        final sheetFinder = find.byType(ChildMapSheet);
        expect(sheetFinder, findsOneWidget);
        expect(
          find.descendant(of: sheetFinder, matching: find.byType(SingleChildScrollView)),
          findsOneWidget,
        );
        expect(
          find.descendant(of: sheetFinder, matching: find.byType(Wrap)),
          findsOneWidget,
        );
        for (final label in [l10n.familyMapRing, l10n.familyMapLock]) {
          final btn = find.descendant(of: sheetFinder, matching: find.text(label));
          expect(btn, findsOneWidget);
          final rect = tester.getRect(btn);
          expect(rect.left, greaterThanOrEqualTo(-0.5));
          expect(rect.right, lessThanOrEqualTo(matrix.size.width + 0.5));
        }
        expectNoOverflow(tester, contextLabel: 'ChildMapSheet [${_caseLabel(matrix)}]');
      });
    }
  });
}
