import 'package:familyshield_parent/features/map/child_location_view.dart';
import 'package:familyshield_parent/features/map/family_map_screen.dart';
import 'package:familyshield_parent/features/map/location_p13_screen.dart';
import 'package:familyshield_parent/l10n/app_localizations.dart';
import 'package:familyshield_parent/providers/auth_provider.dart';
import 'package:familyshield_parent/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geocoding/geocoding.dart';

import 'fake_api_client.dart';

/// #1179 P-13 Location tests (G18, A2, A7, A8).
///
/// Mutant checks:
/// - Removing `p13LocationEnabledProvider` gate breaks the fallback test.
/// - Showing raw lat/lng or a `"Live"` badge fails the forbidden-copy assertions.
/// - Dropping Ring -> Stop ring toggle fails A2; dropping Earlier today fails A7.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  FakeApiClient buildApi({List<String>? sentCommands}) {
    final nowIso = DateTime.now().subtract(const Duration(minutes: 4)).toUtc().toIso8601String();
    return FakeApiClient({
      ...standardRoutes(),
      'GET /v1/location/child-1/latest': (_) => {
            'latest': {
              'deviceId': 'dev-1',
              'lat': 25.1124,
              'lng': 55.1981,
              'accuracyM': 60,
              'timestamp': nowIso,
            },
          },
      'GET /v1/location/child-2/latest': (_) => {
            'latest': {
              'deviceId': 'dev-2',
              'lat': 25.2048,
              'lng': 55.2708,
              'accuracyM': 40,
              'timestamp': nowIso,
            },
          },
      'GET /v1/location/child-1/history': (_) => {
            'pings': [
              {'lat': 25.1124, 'lng': 55.1981, 'accuracyM': 60, 'timestamp': nowIso},
            ],
          },
      'GET /v1/location/geofences/child-1': (_) => {
            'geofences': [
              {
                'id': 'g1',
                'childId': 'child-1',
                'label': 'School',
                'lat': 25.1124,
                'lng': 55.1981,
                'radiusM': 150,
                'notifyOnEnter': true,
                'notifyOnExit': true,
              },
            ],
          },
      'POST /v1/devices/dev-1/command': (req) {
        sentCommands?.add((req.data as Map?)?['command']?.toString() ?? '');
        return {'ok': true};
      },
    });
  }

  PlacemarkLookup fakePlacemark() => (lat, lng, locale) async => [
        const Placemark(
          subLocality: 'Al Barsha',
          locality: 'Dubai',
        ),
      ];

  testWidgets('#1179 P-13 switch ON shows place in words, no Live badge, no raw coordinates, All/child chips, Saved places', (tester) async {
    final cmds = <String>[];
    final api = buildApi(sentCommands: cmds);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(api),
          p13LocationEnabledProvider.overrideWithValue(true),
          placemarkLookupProvider.overrideWithValue(fakePlacemark()),
        ],
        child: MaterialApp(
          theme: AppTheme.light,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const FamilyMapScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('p13MapCard')), findsOneWidget);
    expect(find.byKey(const ValueKey('p13PlaceCard')), findsOneWidget);
    expect(find.textContaining('Al Barsha, Dubai'), findsAtLeastNWidgets(1));
    // Forbidden: raw coordinates and "Live" badge
    expect(find.textContaining('25.1124'), findsNothing);
    expect(find.text('Live'), findsNothing);
    // Chips for All + both children
    expect(find.byKey(const ValueKey('p13Chip-all')), findsOneWidget);
    expect(find.byKey(const ValueKey('p13Chip-child-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('p13Chip-child-2')), findsOneWidget);
    // A8 Saved places + Add place
    expect(find.byKey(const ValueKey('p13SavedPlace-g1')), findsOneWidget);
    expect(find.byKey(const ValueKey('p13AddPlaceButton')), findsOneWidget);
    // A2 Ring -> Stop ringing toggle
    await tester.ensureVisible(find.byKey(const ValueKey('p13RingButton')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('p13RingButton')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('p13RingButton')));
    await tester.pumpAndSettle();
    expect(cmds, ['ring', 'stop_ring']);

    // A7 Earlier today row opens sheet
    await tester.ensureVisible(find.byKey(const ValueKey('p13EarlierTodayRow')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('p13EarlierTodayRow')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Earlier today'), findsAtLeastNWidgets(1));
  });

  testWidgets('#1179 P-13 switch OFF falls back to legacy FamilyMapScreen', (tester) async {
    final api = buildApi();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(api),
          p13LocationEnabledProvider.overrideWithValue(false),
          placemarkLookupProvider.overrideWithValue(fakePlacemark()),
        ],
        child: MaterialApp(
          theme: AppTheme.light,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const FamilyMapScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('p13MapCard')), findsNothing);
    expect(find.byKey(const ValueKey('p13PlaceCard')), findsNothing);
  });

  for (final cfg in [
    (locale: const Locale('en'), dark: false, size: const Size(390, 844), scale: 1.0),
    (locale: const Locale('ar'), dark: false, size: const Size(390, 844), scale: 1.0),
    (locale: const Locale('en'), dark: true, size: const Size(320, 568), scale: 2.0),
    (locale: const Locale('ar'), dark: true, size: const Size(320, 568), scale: 2.0),
  ]) {
    testWidgets(
      '#1179 P-13 Bureau matrix [${cfg.locale.languageCode} | ${cfg.dark ? "dark" : "light"} | ${cfg.size.width.toInt()}x${cfg.size.height.toInt()} | ${cfg.scale}x]',
      (tester) async {
        tester.view.physicalSize = cfg.size;
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        final api = buildApi();
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              apiClientProvider.overrideWithValue(api),
              p13LocationEnabledProvider.overrideWithValue(true),
              placemarkLookupProvider.overrideWithValue(fakePlacemark()),
            ],
            child: MaterialApp(
              locale: cfg.locale,
              theme: AppTheme.light,
              darkTheme: AppTheme.dark,
              themeMode: cfg.dark ? ThemeMode.dark : ThemeMode.light,
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  textScaler: TextScaler.linear(cfg.scale),
                ),
                child: child!,
              ),
              home: const FamilyMapScreen(),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        expect(find.byKey(const ValueKey('p13PlaceCard')), findsOneWidget);
      },
    );
  }
}
