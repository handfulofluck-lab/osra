import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:familyshield_parent/app.dart';
import 'package:familyshield_parent/features/alerts/alerts_screen.dart';
import 'package:familyshield_parent/features/auth/login_screen.dart';
import 'package:familyshield_parent/features/children/child_detail_screen.dart';
import 'package:familyshield_parent/features/content/search_safety_screen.dart';
import 'package:familyshield_parent/features/dashboard/dashboard_screen.dart';
import 'package:familyshield_parent/features/map/family_map_screen.dart';
import 'package:familyshield_parent/features/reports/reports_screen.dart';
import 'package:familyshield_parent/features/reports/usage_history_screen.dart';
import 'package:familyshield_parent/features/rules/rules_editor_screen.dart';
import 'package:familyshield_parent/features/settings/appearance_screen.dart';
import 'package:familyshield_parent/features/settings/digest_prefs_screen.dart';
import 'package:familyshield_parent/features/social/social_screen.dart';
import 'package:familyshield_parent/providers/auth_provider.dart';
import 'package:familyshield_parent/providers/onboarding_provider.dart';
import 'package:familyshield_parent/providers/theme_provider.dart';
import 'package:familyshield_parent/theme/app_theme.dart';
import 'package:familyshield_parent/theme/app_tokens.dart';

import 'fake_api_client.dart';
import 'test_app.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({kOnboardingCompleteKey: true});
  });

  /// WCAG 2.1 relative-luminance contrast ratio.
  double contrastRatio(Color a, Color b) {
    final la = a.computeLuminance();
    final lb = b.computeLuminance();
    final hi = la > lb ? la : lb;
    final lo = la > lb ? lb : la;
    return (hi + 0.05) / (lo + 0.05);
  }

  FakeApiClient designApi() {
    String day(int i) => DateTime.utc(2026, 9, 1).add(Duration(days: i)).toIso8601String().substring(0, 10);
    return FakeApiClient({
      ...standardRoutes(),
      'GET /v1/reports/summary': (_) => {
            'totalAppMinutes': 300,
            'topApps': [
              {'name': 'YouTube', 'minutes': 120},
              {'name': 'TikTok', 'minutes': 90},
            ],
            'urlVisits': 42,
            'topBlockedDomains': [
              {'domain': 'tiktok.com', 'count': 12},
            ],
            'socialConcerns': 2,
            'calls': 7,
            'sms': 15,
          },
      'GET /v1/reports/usage': (req) {
        final days = req.query['days'] as int;
        return {
          'childId': 'child-1',
          'days': days,
          'totalMinutes': days * 10,
          'series': [
            for (var i = 0; i < days; i++) {'day': day(i), 'minutes': 10, 'apps': const <Map<String, dynamic>>[]},
          ],
        };
      },
      'GET /v1/reports/web': (_) => {
            'childId': 'child-1',
            'days': 7,
            'items': [
              {
                'id': 'v1',
                'childId': 'child-1',
                'deviceId': 'dev-1',
                'domain': 'tiktok.com',
                'url': 'https://tiktok.com/page',
                'blocked': true,
                'category': 'social',
                'ts': DateTime.now().subtract(const Duration(minutes: 5)).toUtc().toIso8601String(),
              },
            ],
          },
      // The migrated screens' feeds: one card of each severity so the
      // severity rule and its labels are on screen in the dark layout test.
      'GET /v1/content/searches': (_) => {
            'items': [
              {
                'id': 's-1',
                'engine': 'google',
                'query': 'how to buy vape',
                'severity': 'critical',
                'concernTypes': ['drugs'],
                'createdAt': DateTime.now().subtract(const Duration(minutes: 5)).toUtc().toIso8601String(),
              },
              {
                'id': 's-2',
                'engine': 'youtube',
                'query': 'dangerous stunt tutorial',
                'severity': 'warning',
                'concernTypes': ['violence'],
                'createdAt': DateTime.now().subtract(const Duration(hours: 1)).toUtc().toIso8601String(),
              },
            ],
          },
      'GET /v1/digests/prefs': (_) => {
            'dailyEmail': true,
            'weeklyEmail': false,
            'pushEnabled': true,
            'emails': ['qa@familyshield.dev'],
          },
      'GET /v1/location/geofences/child-1': (_) => {'items': <dynamic>[]},
      'GET /v1/location/geofences/child-2': (_) => {'items': <dynamic>[]},
    });
  }

  /// Theme + fake API harness that rebuilds when the persisted mode changes,
  /// exactly like `FamilyShieldApp` does.
  Widget themedApp(Widget home, FakeApiClient api) => ProviderScope(
        overrides: [apiClientProvider.overrideWithValue(api)],
        child: Consumer(
          builder: (context, ref, _) => localizedTestApp(
            home,
            theme: AppTheme.light,
            darkTheme: AppTheme.dark,
            themeMode: ref.watch(themeModeProvider),
          ),
        ),
      );

  List<Object> drainExceptions(WidgetTester tester) {
    final exceptions = <Object>[];
    while (true) {
      final e = tester.takeException();
      if (e == null) return exceptions;
      exceptions.add(e);
    }
  }

  group('design tokens', () {
    test('AppTheme publishes the token layer for both brightnesses', () {
      final light = AppTheme.light.extension<AppTokens>();
      final dark = AppTheme.dark.extension<AppTokens>();
      expect(light, isNotNull);
      expect(dark, isNotNull);
      expect(AppTheme.light.brightness, Brightness.light);
      expect(AppTheme.dark.brightness, Brightness.dark);
      expect(light!.surface, isNot(dark!.surface));
      expect(light.onSurface, isNot(dark.onSurface));
      expect(light.danger, isNot(dark.danger));
      // Spacing/radius/type are stateless and shared by both themes.
      expect(AppSpace.md, greaterThan(AppSpace.sm));
      expect(AppRadius.md, greaterThan(AppRadius.sm));
      expect(AppTheme.dark.textTheme.bodyMedium?.fontSize, AppType.textTheme.bodyMedium?.fontSize);
    });

    test('danger, warn and ok keep at least 4.5:1 contrast on both surfaces', () {
      for (final entry in {'light': AppTokens.light, 'dark': AppTokens.dark}.entries) {
        final tokens = entry.value;
        final roles = {'danger': tokens.danger, 'warn': tokens.warn, 'ok': tokens.ok};
        for (final role in roles.entries) {
          for (final surface in {'surface': tokens.surface, 'surfaceVariant': tokens.surfaceVariant}.entries) {
            final ratio = contrastRatio(role.value, surface.value);
            expect(
              ratio,
              greaterThanOrEqualTo(4.5),
              reason: '${entry.key}/${role.key} on ${surface.key} is ${ratio.toStringAsFixed(2)}:1',
            );
          }
        }
      }
    });

    test('severity labels keep 4.5:1 on surfaces and on their own tint', () {
      for (final entry in {'light': AppTokens.light, 'dark': AppTokens.dark}.entries) {
        final tokens = entry.value;
        final roles = [
          ('critical', tokens.severityCriticalText, tokens.severityCritical),
          ('warning', tokens.severityWarningText, tokens.severityWarning),
          ('info', tokens.severityInfoText, tokens.severityInfo),
        ];
        for (final (name, text, dot) in roles) {
          final backgrounds = {
            'surface': tokens.surface,
            'surfaceVariant': tokens.surfaceVariant,
            '7% tint': Color.alphaBlend(dot.withValues(alpha: 0.07), tokens.surfaceVariant),
            '15% tint': Color.alphaBlend(dot.withValues(alpha: 0.15), tokens.surfaceVariant),
          };
          for (final background in backgrounds.entries) {
            final ratio = contrastRatio(text, background.value);
            expect(
              ratio,
              greaterThanOrEqualTo(4.5),
              reason: '${entry.key}/$name label on ${background.key} is ${ratio.toStringAsFixed(2)}:1',
            );
          }
        }
      }
    });

    test('the swipe-to-acknowledge pair keeps 4.5:1 in both themes', () {
      for (final entry in {'light': AppTokens.light, 'dark': AppTokens.dark}.entries) {
        final tokens = entry.value;
        final ratio = contrastRatio(tokens.onOk, tokens.ok);
        expect(
          ratio,
          greaterThanOrEqualTo(4.5),
          reason: '${entry.key}/onOk on ok is ${ratio.toStringAsFixed(2)}:1',
        );
      }
    });

    test('the light severity dots keep the pinned Material values', () {
      // widget_screens_test.dart pins these in the AlertsScreen; the token
      // contract has to keep them (including runtime type) so a dark-mode
      // remap can never change what a light-mode user sees.
      expect(AppTokens.light.severityCritical, Colors.red);
      expect(AppTokens.light.severityWarning, Colors.amber);
      expect(AppTokens.light.severityInfo, Colors.blue);
      expect(AppTokens.dark.severityCritical, isNot(AppTokens.light.severityCritical));
      expect(AppTokens.dark.severityWarning, isNot(AppTokens.light.severityWarning));
      expect(AppTokens.dark.severityInfo, isNot(AppTokens.light.severityInfo));
    });

    test('severity lookups are case-insensitive and default to info', () {
      for (final tokens in [AppTokens.light, AppTokens.dark]) {
        expect(tokens.severityDot('WARNING'), tokens.severityWarning);
        expect(tokens.severityText('Critical'), tokens.severityCriticalText);
        expect(tokens.severityDot('unknown'), tokens.severityInfo);
        expect(tokens.severityText(''), tokens.severityInfoText);
      }
    });
  });

  group('appearance', () {
    testWidgets('the app follows platformBrightness in system mode', (tester) async {
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
      final api = FakeApiClient(standardRoutes());

      await tester.pumpWidget(ProviderScope(
        overrides: [apiClientProvider.overrideWithValue(api)],
        child: const FamilyShieldApp(),
      ));
      await tester.pumpAndSettle();

      expect(find.byType(LoginScreen), findsOneWidget);
      expect(Theme.of(tester.element(find.byType(LoginScreen))).brightness, Brightness.dark);
    });

    testWidgets('Settings → Appearance forces dark, persists it, and a rebuilt tree opens dark',
        (tester) async {
      final api = designApi();
      await tester.pumpWidget(themedApp(const AppearanceScreen(), api));
      await tester.pumpAndSettle();

      // Default is system and this test platform is light.
      expect(Theme.of(tester.element(find.byType(AppearanceScreen))).brightness, Brightness.light);

      await tester.tap(find.text('Dark'));
      await tester.pumpAndSettle();

      expect(Theme.of(tester.element(find.byType(AppearanceScreen))).brightness, Brightness.dark);
      expect((await SharedPreferences.getInstance()).getString(kThemeModeKey), 'dark');

      // Tear the tree down completely and build a fresh one: the persisted
      // choice, not the in-memory notifier, has to restore dark.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      await tester.pumpWidget(themedApp(const AppearanceScreen(), api));
      await tester.pumpAndSettle();

      expect(Theme.of(tester.element(find.byType(AppearanceScreen))).brightness, Brightness.dark);
      expect(
        tester.widget<SegmentedButton<ThemeMode>>(find.byKey(const ValueKey('themeModeSelector'))).selected,
        {ThemeMode.dark},
      );
    });
  });

  group('severity in dark mode', () {
    testWidgets('AlertsScreen resolves dots through the dark token set', (tester) async {
      SharedPreferences.setMockInitialValues({kThemeModeKey: 'dark'});
      await tester.pumpWidget(themedApp(const AlertsScreen(), designApi()));
      await tester.pumpAndSettle();

      Color dot(String title) => tester
          .widget<Icon>(find.descendant(
            of: find.ancestor(of: find.text(title), matching: find.byType(AlertTile)),
            matching: find.byIcon(Icons.circle),
          ))
          .color!;

      expect(dot('SOS pressed'), AppTokens.dark.severityCritical);
      expect(dot('Blocked site visited'), AppTokens.dark.severityWarning);
      expect(dot('Daily limit reached'), AppTokens.dark.severityInfo);
    });

    testWidgets('SearchSafetyScreen uses the readable dark severity label', (tester) async {
      SharedPreferences.setMockInitialValues({kThemeModeKey: 'dark'});
      await tester.pumpWidget(themedApp(const SearchSafetyScreen(childId: 'child-1'), designApi()));
      await tester.pumpAndSettle();

      expect(tester.widget<Text>(find.text('CRITICAL')).style?.color, AppTokens.dark.severityCriticalText);
      expect(tester.widget<Text>(find.text('WARNING')).style?.color, AppTokens.dark.severityWarningText);
    });
  });

  group('dark layout at 320x568', () {
    for (final (name, screen) in <(String, Widget)>[
      ('dashboard', const DashboardScreen()),
      ('reports', const ReportsScreen(childId: 'child-1')),
      ('usage history', const UsageHistoryScreen(childId: 'child-1')),
      ('child detail', const ChildDetailScreen(childId: 'child-1')),
      ('family map', const FamilyMapScreen()),
      ('rules editor', const RulesEditorScreen(childId: 'child-1')),
      ('social', const SocialScreen(childId: 'child-1')),
      ('search safety', const SearchSafetyScreen(childId: 'child-1')),
      ('digest preferences', const DigestPrefsScreen()),
    ]) {
      testWidgets('$name renders in dark mode without overflow', (tester) async {
        SharedPreferences.setMockInitialValues({kThemeModeKey: 'dark'});
        tester.view.physicalSize = const Size(320, 568);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        await tester.pumpWidget(themedApp(screen, designApi()));
        await tester.pumpAndSettle();

        final context = tester.element(find.byType(Scaffold).first);
        expect(Theme.of(context).brightness, Brightness.dark);
        final exceptions = drainExceptions(tester);
        expect(exceptions, isEmpty, reason: exceptions.join('\n'));
      });
    }
  });
}
