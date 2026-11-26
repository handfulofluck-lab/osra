import 'package:familyshield_parent/features/dashboard/home_p07_screen.dart';
import 'package:familyshield_parent/features/onboarding/welcome_p01_screen.dart';
import 'package:familyshield_parent/features/onboarding/welcome_screen.dart';
import 'package:familyshield_parent/l10n/app_localizations.dart';
import 'package:familyshield_parent/providers/locale_provider.dart';
import 'package:familyshield_parent/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

class _TestLocaleNotifier extends AppLocaleNotifier {
  _TestLocaleNotifier(Locale initial) {
    state = initial;
  }

  @override
  Future<void> setLocale(Locale? locale) async {
    state = locale;
  }
}

Widget _harness({
  required bool p01Enabled,
  Locale locale = const Locale('en'),
  ThemeMode themeMode = ThemeMode.light,
  double textScale = 1.0,
  List<String>? navigated,
  _TestLocaleNotifier? localeNotifier,
}) {
  final router = GoRouter(
    initialLocation: '/welcome',
    routes: [
      GoRoute(path: '/welcome', builder: (_, __) => const WelcomeScreen()),
      GoRoute(
        path: '/create-account',
        builder: (_, __) {
          navigated?.add('/create-account');
          return const Scaffold(body: Text('CREATE_ACCOUNT_DEST'));
        },
      ),
      GoRoute(
        path: '/sign-in',
        builder: (_, __) {
          navigated?.add('/sign-in');
          return const Scaffold(body: Text('SIGN_IN_DEST'));
        },
      ),
    ],
  );
  return ProviderScope(
    key: UniqueKey(),
    overrides: [
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
  testWidgets(
      'P-01 switch ON shows 4 real HomeP07PreviewTile cards, Example badge, language switch, 2 distinct buttons, no-ads line, and no forbidden claims',
      (tester) async {
    final nav = <String>[];
    await tester.pumpWidget(_harness(p01Enabled: true, navigated: nav));
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
    expect(nav, ['/create-account']);
  });

  testWidgets('P-01 Sign in button routes to /sign-in separately from Create account', (tester) async {
    final nav = <String>[];
    await tester.pumpWidget(_harness(p01Enabled: true, navigated: nav));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(find.byKey(const ValueKey('p01-sign-in')), 150);
    await tester.tap(find.byKey(const ValueKey('p01-sign-in')));
    await tester.pumpAndSettle();
    expect(nav, ['/sign-in']);
  });

  testWidgets('P-01 language switch toggles locale EN -> AR -> EN', (tester) async {
    final localeNotifier = _TestLocaleNotifier(const Locale('en'));
    await tester.pumpWidget(_harness(
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

  testWidgets('P-01 switch OFF falls back to legacy WelcomeScreen', (tester) async {
    await tester.pumpWidget(_harness(p01Enabled: false));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('onboardingGetStarted')), findsOneWidget);
    expect(find.byKey(const ValueKey('p01-example-badge')), findsNothing);
  });

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

      await tester.pumpWidget(_harness(
        p01Enabled: true,
        locale: locale,
        themeMode: mode,
        textScale: scale,
      ));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'Failed on $locale $mode $size @ ${scale}x');
    }
  });
}
