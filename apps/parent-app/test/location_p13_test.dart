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
import 'package:google_maps_flutter/google_maps_flutter.dart';

import 'fake_api_client.dart';

/// #1179 P-13 Location tests (G18, G6, A2, A7, A8 + Kimi-Mac B1–B4).
///
/// Mutant checks:
/// - Removing `p13LocationEnabledProvider` gate breaks the fallback test.
/// - Showing only one marker in All mode breaks B1.
/// - Enabling Ring on iOS breaks B2.
/// - Ignoring `{status: 'failed', reason}` on Ring breaks B3.
/// - Swallowing locate POST / location GET / geofences GET errors breaks B4.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  FakeApiClient buildApi({
    List<String>? sentCommands,
    String child1Platform = 'android',
    Object? Function(dynamic req)? commandResponse,
    bool failLocationGet = false,
    bool failGeofencesGet = false,
  }) {
    final nowIso = DateTime.now().subtract(const Duration(minutes: 4)).toUtc().toIso8601String();
    final routes = standardRoutes();
    if (child1Platform == 'ios') {
      routes['GET /v1/family/me'] = (_) => familyMeTwoChildren(alexPlatform: 'ios');
    }
    return FakeApiClient({
      ...routes,
      'GET /v1/location/child-1/latest': (_) {
        if (failLocationGet) throw FakeNetworkError();
        return {
          'latest': {
            'deviceId': 'dev-1',
            'lat': 25.1124,
            'lng': 55.1981,
            'accuracyM': 60,
            'timestamp': nowIso,
          },
        };
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
      'GET /v1/location/geofences/child-1': (_) {
        if (failGeofencesGet) throw FakeNetworkError();
        return {
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
        };
      },
      'POST /v1/devices/dev-1/command': (req) {
        sentCommands?.add((req.data as Map?)?['command']?.toString() ?? '');
        if (commandResponse != null) return commandResponse(req);
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

  testWidgets('#1179 P-13 switch ON: All mode renders both child pins (B1), no Live/raw coords, Ring toggle (A2), Earlier today (A7)', (tester) async {
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
    expect(find.byKey(const ValueKey('p13AllChildrenMap')), findsOneWidget);
    final mapWidget = tester.widget<GoogleMap>(find.byKey(const ValueKey('p13AllChildrenMap')));
    expect(mapWidget.markers.map((m) => m.markerId.value), containsAll(['child-1', 'child-2']));

    expect(find.byKey(const ValueKey('p13PlaceCard')), findsOneWidget);
    expect(find.textContaining('Al Barsha, Dubai'), findsAtLeastNWidgets(1));
    expect(find.textContaining('25.1124'), findsNothing);
    expect(find.text('Live'), findsNothing);
    expect(find.byKey(const ValueKey('p13Chip-all')), findsOneWidget);
    expect(find.byKey(const ValueKey('p13Chip-child-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('p13Chip-child-2')), findsOneWidget);
    expect(find.byKey(const ValueKey('p13SavedPlace-g1')), findsOneWidget);
    expect(find.byKey(const ValueKey('p13AddPlaceButton')), findsOneWidget);

    await tester.ensureVisible(find.byKey(const ValueKey('p13RingButton')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('p13RingButton')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('p13RingButton')));
    await tester.pumpAndSettle();
    expect(cmds, ['ring', 'stop_ring']);

    await tester.ensureVisible(find.byKey(const ValueKey('p13EarlierTodayRow')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('p13EarlierTodayRow')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Earlier today'), findsAtLeastNWidgets(1));
  });

  testWidgets('#1179 P-13 B2: iPhone child shows Not yet available on iPhone and sends zero Ring POSTs', (tester) async {
    final cmds = <String>[];
    final api = buildApi(sentCommands: cmds, child1Platform: 'ios');
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

    expect(find.text('Not yet available on iPhone'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const ValueKey('p13RingButton')));
    await tester.tap(find.byKey(const ValueKey('p13RingButton')));
    await tester.pumpAndSettle();
    expect(cmds, isEmpty);
  });

  testWidgets('#1179 P-13 B3: up-front refused Ring shows refusal snackbar and does not flip to Stop ringing', (tester) async {
    final cmds = <String>[];
    final api = buildApi(
      sentCommands: cmds,
      commandResponse: (_) => {'status': 'failed', 'reason': 'unsupported_command'},
    );
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

    await tester.ensureVisible(find.byKey(const ValueKey('p13RingButton')));
    await tester.tap(find.byKey(const ValueKey('p13RingButton')));
    await tester.pumpAndSettle();
    expect(cmds, ['ring']);
    expect(find.text('Stop ringing'), findsNothing);
    expect(find.byType(SnackBar), findsOneWidget);
  });

  testWidgets('#1179 P-13 B4: location/geofence read failures show error + retry instead of empty state, and locate POST failure shows snackbar', (tester) async {
    final api = buildApi(
      failLocationGet: true,
      failGeofencesGet: true,
      commandResponse: (_) => throw FakeNetworkError(),
    );
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
          home: const LocationP13Screen(initialChildId: 'child-1'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('p13LocationError')), findsOneWidget);
    expect(find.byKey(const ValueKey('p13GeofencesError')), findsOneWidget);
    expect(find.text('No location reported yet.'), findsNothing);

    await tester.ensureVisible(find.byKey(const ValueKey('p13RefreshButton')));
    await tester.tap(find.byKey(const ValueKey('p13RefreshButton')));
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsOneWidget);
  });

  // Mutant: reverting `_AllChildrenP13Map` iOS fallback to `ChildLocationMap(pins.first)`
  // drops `osmPin-child-2` and fails this test (Kimi-Mac B5).
  testWidgets('#1179 P-13 B5: no-Google-key / iPhone path renders both osmPin-child-1 and osmPin-child-2 in All mode',
      (tester) async {
    final api = buildApi();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(api),
          p13LocationEnabledProvider.overrideWithValue(true),
          placemarkLookupProvider.overrideWithValue(fakePlacemark()),
        ],
        child: MaterialApp(
          theme: AppTheme.light.copyWith(platform: TargetPlatform.iOS),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const FamilyMapScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('p13AllChildrenOsmMap')), findsOneWidget);
    expect(find.byKey(const ValueKey('osmPin-child-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('osmPin-child-2')), findsOneWidget);
  });

  // Mutant: placing battery beside PlaceNameText in the same Row causes horizontal overlap/collision
  // at 320px/200% and fails this geometry check (Kimi-Mac B6).
  testWidgets('#1179 P-13 B6: battery label stays below address without colliding at 320px / 200% in EN and AR',
      (tester) async {
    for (final locale in const [Locale('en'), Locale('ar')]) {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final api = buildApi();
      await tester.pumpWidget(
        ProviderScope(
          key: UniqueKey(),
          overrides: [
            apiClientProvider.overrideWithValue(api),
            p13LocationEnabledProvider.overrideWithValue(true),
            placemarkLookupProvider.overrideWithValue(fakePlacemark()),
          ],
          child: MaterialApp(
            locale: locale,
            theme: AppTheme.light,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(2.0)),
              child: child!,
            ),
            home: const FamilyMapScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final placeFinder = find.descendant(
        of: find.byKey(const ValueKey('p13PlaceCard')),
        matching: find.byType(PlaceNameText),
      );
      final batteryFinder = find.byKey(const ValueKey('p13BatteryLabel'));
      expect(placeFinder, findsOneWidget);
      expect(batteryFinder, findsOneWidget);
      final placeRect = tester.getRect(placeFinder);
      final batteryRect = tester.getRect(batteryFinder);
      expect(
        batteryRect.top,
        greaterThanOrEqualTo(placeRect.bottom),
        reason: 'Battery must sit on its own row below PlaceNameText in $locale',
      );
    }
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
    (locale: const Locale('en'), dark: true, size: const Size(390, 844), scale: 1.0),
    (locale: const Locale('ar'), dark: false, size: const Size(390, 844), scale: 1.0),
    (locale: const Locale('ar'), dark: true, size: const Size(390, 844), scale: 1.0),
    (locale: const Locale('en'), dark: false, size: const Size(320, 568), scale: 2.0),
    (locale: const Locale('en'), dark: true, size: const Size(320, 568), scale: 2.0),
    (locale: const Locale('ar'), dark: false, size: const Size(320, 568), scale: 2.0),
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
