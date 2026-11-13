import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:familyshield_parent/features/dashboard/dashboard_screen.dart';
import 'package:familyshield_parent/features/map/family_map_screen.dart';
import 'package:familyshield_parent/l10n/app_localizations.dart';
import 'package:familyshield_parent/providers/auth_provider.dart';
import 'package:familyshield_parent/providers/family_provider.dart';
import 'fake_api_client.dart';

/// #406, Claude's ruling: a refused location or geofence read names the owner instead of looking like
/// "no location yet". The helper has its own rows; these check the dashboard and the map actually render it.

DioException refusal([String path = '/v1/location/child-1/latest']) => DioException(
      requestOptions: RequestOptions(path: path),
      response: Response(
        requestOptions: RequestOptions(path: path),
        statusCode: 403,
        data: {'error': 'permission_required', 'permission': 'location'},
      ),
    );

Future<void> pumpWith(WidgetTester tester, Widget home, List<Override> overrides) async {
  final api = FakeApiClient(standardRoutes());
  await tester.pumpWidget(ProviderScope(
    overrides: [apiClientProvider.overrideWithValue(api), ...overrides],
    child: MaterialApp(
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('en'),
      home: home,
    ),
  ));
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));

  testWidgets('a refused location read says the owner can grant access, not "no location yet"', (tester) async {
    await pumpWith(tester, const DashboardScreen(), [
      locationProvider('child-1').overrideWith((ref) => throw refusal()),
    ]);
    // child-1 is refused and names the owner; child-2 is not refused, so it still says "no location yet".
    expect(find.text(l10n.readPermissionRequired), findsOneWidget);
    expect(find.text(l10n.noLocationYet), findsOneWidget);
  });

  group('family map banner', () {
    testWidgets('a refused geofence read on the second child shows the banner', (tester) async {
      await pumpWith(tester, const FamilyMapScreen(), [
        geofencesProvider('child-2').overrideWith((ref) => throw refusal('/v1/location/geofences')),
      ]);
      expect(find.text(l10n.readPermissionRequired), findsOneWidget);
    });

    testWidgets('every child refused still shows one banner, not one per child', (tester) async {
      await pumpWith(tester, const FamilyMapScreen(), [
        locationProvider('child-1').overrideWith((ref) => throw refusal()),
        locationProvider('child-2').overrideWith((ref) => throw refusal('/v1/location/child-2/latest')),
      ]);
      expect(find.text(l10n.readPermissionRequired), findsOneWidget);
    });

    testWidgets('nothing refused, no banner', (tester) async {
      await pumpWith(tester, const FamilyMapScreen(), const []);
      expect(find.text(l10n.readPermissionRequired), findsNothing);
    });
  });

/// #598: on iOS the Google Maps SDK aborts in `checkServicePreconditions` when `GMSServices.provideAPIKey`
/// was never called. `mapIsAvailable` is the pure decision; these rows pin that the screen honours it, which
/// is the half a unit test of the predicate cannot see.
  test("a build with no iOS maps key draws no map view, and does not throw", () {
    expect(mapIsAvailable(TargetPlatform.iOS, key: ""), isFalse);
    expect(mapIsAvailable(TargetPlatform.iOS, key: "a-real-key"), isTrue);
    // Android gets its key from the Gradle manifest, which Dart cannot read; the crash is iOS-only.
    expect(mapIsAvailable(TargetPlatform.android, key: ""), isTrue);
  });

  testWidgets("the map screen shows the not-available state on iOS when no key is compiled in", (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      await pumpWith(tester, const FamilyMapScreen(), const []);
      // The card is the existing approved string; no GoogleMap is constructed, which is what crashed.
      expect(find.text('Not available'), findsOneWidget);
      expect(find.byType(GoogleMap), findsNothing);
      expect(tester.takeException(), isNull);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
