import 'package:familyshield_parent/app.dart' show appRoutes;
import 'package:familyshield_parent/features/auth/create_account_screen.dart';
import 'package:familyshield_parent/features/auth/login_screen.dart';
import 'package:familyshield_parent/features/dashboard/home_p07_screen.dart';
import 'package:familyshield_parent/features/onboarding/welcome_p01_screen.dart';
import 'package:familyshield_parent/l10n/app_localizations.dart';
import 'package:familyshield_parent/providers/auth_provider.dart';
import 'package:familyshield_parent/providers/locale_provider.dart';
import 'package:familyshield_parent/providers/server_provider.dart';
import 'package:familyshield_parent/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'fake_api_client.dart';

class _TestLocaleNotifier extends AppLocaleNotifier {
  _TestLocaleNotifier(Locale initial) {
    state = initial;
  }

  @override
  Future<void> setLocale(Locale? locale) async {
    state = locale;
  }
}

class _FixedServerNotifier extends ServerUrlNotifier {
  _FixedServerNotifier(String url) : super(FakeApiClient({})) {
    state = url;
  }

  @override
  Future<void> ensureApplied() async {}
}

Widget _realRouterHarness({
  required bool p01Enabled,
  String serverUrl = 'https://api.osratech.com',
  Locale locale = const Locale('en'),
  ThemeMode themeMode = ThemeMode.light,
  double textScale = 1.0,
  _TestLocaleNotifier? localeNotifier,
}) {
  final api = FakeApiClient({
    ...standardRoutes(),
    'GET /v1/consent-copy': (_) => {
          'version': '2026-11',
          'purposes': {
            'account': {
              'sentence': 'I agree to the Terms and Privacy Policy.',
              'links': [
                {'label': 'Terms', 'url': 'https://osratech.com/terms'},
                {'label': 'Privacy', 'url': 'https://osratech.com/privacy'},
              ],
            },
          },
        },
  });
  final router = GoRouter(
    initialLocation: '/welcome',
    routes: appRoutes,
  );
  return ProviderScope(
    key: UniqueKey(),
    overrides: [
      apiClientProvider.overrideWithValue(api),
      serverUrlProvider.overrideWith((_) => _FixedServerNotifier(serverUrl)),
      p01WelcomeEnabledProvider.overrideWithValue(p01Enabled),
      if (localeNotifier != null) localeProvider.overrideWith((_) => localeNotifier),
    ],
    child: Consumer(
      builder: (context, ref, _) {
        final effectiveLocale = localeNotifier != null
            ? (ref.watch(localeProvider) ?? locale)
            : locale;
        return MaterialApp.router(
          locale: effectiveLocale,
          theme: AppTheme.light,
          darkTheme: AppTheme.dark,
          themeMode: themeMode,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          routerConfig: router,
        );
      },
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  // Mutant: replacing `context.push('/create-account')` with `context.go('/create-account')`
  // removes Welcome from the Back stack and fails the Back-navigation assertion.
  testWidgets(
      'P-01 switch ON shows 4 HomeP07PreviewTile cards, no speed/forbidden claims, and Create account pushes CreateAccountScreen with real Back to Welcome',
      (tester) async {
    await tester.pumpWidget(_realRouterHarness(p01Enabled: true));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('p01-example-badge')), findsOneWidget);
    expect(find.byKey(const ValueKey('p01-preview-grid')), findsOneWidget);
    expect(find.byType(HomeP07PreviewTile), findsNWidgets(4));
    expect(find.byKey(const ValueKey('p01-language-switch')), findsOneWidget);
    expect(find.byKey(const ValueKey('p01-create-account')), findsOneWidget);
    expect(find.byKey(const ValueKey('p01-sign-in')), findsOneWidget);
    expect(find.byKey(const ValueKey('p01-no-ads')), findsOneWidget);

    // Forbidden claims: no residency, speed ("five minutes"), or "on-device" copy, and no Tooltip.
    expect(find.textContaining('UAE'), findsNothing);
    expect(find.textContaining('five minutes'), findsNothing);
    expect(find.textContaining('minutes'), findsNothing);
    expect(find.textContaining('on-device'), findsNothing);
    expect(find.byType(Tooltip), findsNothing);

    await tester.scrollUntilVisible(find.byKey(const ValueKey('p01-create-account')), 150);
    await tester.tap(find.byKey(const ValueKey('p01-create-account')));
    await tester.pumpAndSettle();
    expect(find.byType(CreateAccountScreen), findsOneWidget);

    // Real Back navigation returns to Welcome so an accidental tap keeps Sign in reachable.
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(WelcomeP01Screen), findsOneWidget);
    expect(find.byKey(const ValueKey('p01-sign-in')), findsOneWidget);
  });

  // Mutant: removing the `!hasServer` guard sends an unlocked build with no saved server
  // straight to CreateAccountScreen instead of LoginScreen where the server URL can be entered.
  testWidgets(
      'P-01 Create account on unlocked build with empty server routes to LoginScreen for server setup and preserves Back to Welcome',
      (tester) async {
    await tester.pumpWidget(_realRouterHarness(p01Enabled: true, serverUrl: ''));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(find.byKey(const ValueKey('p01-create-account')), 150);
    await tester.tap(find.byKey(const ValueKey('p01-create-account')));
    await tester.pumpAndSettle();
    expect(find.byType(LoginScreen), findsOneWidget);
    expect(find.byType(CreateAccountScreen), findsNothing);

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(WelcomeP01Screen), findsOneWidget);
  });

  // Mutant: wiring Sign in to `/create-account` fails `LoginScreen`.
  testWidgets('P-01 Sign in button pushes LoginScreen separately from Create account', (tester) async {
    await tester.pumpWidget(_realRouterHarness(p01Enabled: true));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(find.byKey(const ValueKey('p01-sign-in')), 150);
    await tester.tap(find.byKey(const ValueKey('p01-sign-in')));
    await tester.pumpAndSettle();
    expect(find.byType(LoginScreen), findsOneWidget);
  });

  // Mutant: removing `localeProvider.notifier.setLocale` fails the locale toggle check.
  testWidgets('P-01 language switch toggles locale EN -> AR -> EN', (tester) async {
    final localeNotifier = _TestLocaleNotifier(const Locale('en'));
    await tester.pumpWidget(_realRouterHarness(
      p01Enabled: true,
      locale: const Locale('en'),
      localeNotifier: localeNotifier,
    ));
    await tester.pumpAndSettle();

    expect(localeNotifier.state, const Locale('en'));
    await tester.tap(find.byKey(const ValueKey('p01-language-switch')));
    await tester.pumpAndSettle();
    expect(localeNotifier.state, const Locale('ar'));

    await tester.tap(find.byKey(const ValueKey('p01-language-switch')));
    await tester.pumpAndSettle();
    expect(localeNotifier.state, const Locale('en'));
  });

  // Mutant: removing `p01WelcomeEnabledProvider` gate fails the fallback check.
  testWidgets('P-01 switch OFF falls back to legacy WelcomeScreen', (tester) async {
    await tester.pumpWidget(_realRouterHarness(p01Enabled: false));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('onboardingGetStarted')), findsOneWidget);
    expect(find.byKey(const ValueKey('p01-example-badge')), findsNothing);
  });

  // Mutant: removing P-01 switch fails `p01-welcome-title` inside the 8-combo matrix.
  testWidgets('Bureau matrix: zero overflow across all 8 combos (EN/AR x light/dark x 390@1x and 320@2x)',
      (tester) async {
    final configs = [
      (const Locale('en'), ThemeMode.light, const Size(390, 844), 1.0),
      (const Locale('en'), ThemeMode.dark, const Size(390, 844), 1.0),
      (const Locale('ar'), ThemeMode.light, const Size(390, 844), 1.0),
      (const Locale('ar'), ThemeMode.dark, const Size(390, 844), 1.0),
      (const Locale('en'), ThemeMode.light, const Size(320, 568), 2.0),
      (const Locale('en'), ThemeMode.dark, const Size(320, 568), 2.0),
      (const Locale('ar'), ThemeMode.light, const Size(320, 568), 2.0),
      (const Locale('ar'), ThemeMode.dark, const Size(320, 568), 2.0),
    ];

    for (final (locale, mode, size, scale) in configs) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_realRouterHarness(
        p01Enabled: true,
        locale: locale,
        themeMode: mode,
        textScale: scale,
      ));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'Failed on $locale $mode $size @ ${scale}x');
      expect(find.byKey(const ValueKey('p01-welcome-title')), findsOneWidget);
    }
  });
}
