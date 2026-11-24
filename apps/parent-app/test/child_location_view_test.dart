import 'package:familyshield_parent/api/models.dart';
import 'package:familyshield_parent/features/children/child_detail_screen.dart';
import 'package:familyshield_parent/features/map/child_location_view.dart';
import 'package:familyshield_parent/providers/auth_provider.dart';
import 'package:familyshield_parent/providers/clock_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geocoding/geocoding.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_api_client.dart';
import 'test_app.dart';

/// Karim's 22 Nov test: the child card showed raw coordinates and the profile a grey "Map preview" box.
/// A parent reads a place name and how fresh it is, never coordinates, and the profile draws a real map.
void main() {
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  final now = DateTime(2026, 11, 23, 12, 0);
  final ping = LocationPing(
    deviceId: 'dev-1',
    lat: 25.11318,
    lng: 55.20034,
    accuracyM: 18,
    timestamp: now.subtract(const Duration(minutes: 4)),
  );

  List<Override> overrides({List<Placemark>? marks, bool fail = false}) => [
        clockProvider.overrideWithValue(() => now),
        placemarkLookupProvider.overrideWithValue((lat, lng, locale) async {
          if (fail) throw Exception('geocoder offline');
          return marks ?? const [];
        }),
      ];

  group('formatPlacemark', () {
    test('street, neighbourhood and city, without empty or repeated parts', () {
      expect(
        formatPlacemark(const Placemark(
          thoroughfare: 'Al Khail Rd',
          subLocality: 'Al Barsha',
          locality: 'Dubai',
          administrativeArea: 'Dubai',
        )),
        'Al Khail Rd, Al Barsha, Dubai',
      );
      expect(formatPlacemark(const Placemark(subLocality: ' ', locality: 'Dubai')), 'Dubai');
    });

    test('falls back to the name, and to null when there is nothing to say', () {
      expect(formatPlacemark(const Placemark(name: 'Dubai Mall')), 'Dubai Mall');
      expect(formatPlacemark(const Placemark()), isNull);
    });

    test('Arabic results use the Arabic comma', () {
      expect(
        formatPlacemark(const Placemark(subLocality: 'البرشاء', locality: 'دبي'), separator: '، '),
        'البرشاء، دبي',
      );
    });
  });

  testWidgets('the card line names the place and its freshness, never coordinates', (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: overrides(marks: const [Placemark(subLocality: 'Al Barsha', locality: 'Dubai')]),
      child: localizedTestApp(Scaffold(body: PlaceSummaryLine(ping: ping))),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Al Barsha, Dubai'), findsOneWidget);
    expect(find.text('Updated 4 min ago'), findsOneWidget);
    expect(find.textContaining('25.11'), findsNothing, reason: 'raw coordinates are not shown to a parent');
  });

  testWidgets('a failed lookup says the address is not available, still without coordinates', (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: overrides(fail: true),
      child: localizedTestApp(Scaffold(body: PlaceSummaryLine(ping: ping))),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Address not available'), findsOneWidget);
    expect(find.textContaining('25.11'), findsNothing);
  });

  testWidgets('Arabic freshness and fallback read in Arabic', (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: overrides(fail: true),
      child: localizedTestApp(Scaffold(body: PlaceSummaryLine(ping: ping)), locale: const Locale('ar')),
    ));
    await tester.pumpAndSettle();

    expect(find.text('العنوان غير متوفر'), findsOneWidget);
    expect(find.text('آخر تحديث قبل 4 دقائق'), findsOneWidget);
  });

  testWidgets('a fix older than 30 minutes is flagged with a clock icon; a recent one is not', (tester) async {
    final old = LocationPing(deviceId: 'dev-1', lat: ping.lat, lng: ping.lng, timestamp: now.subtract(const Duration(hours: 2)));
    await tester.pumpWidget(ProviderScope(
      overrides: overrides(marks: const [Placemark(locality: 'Dubai')]),
      child: localizedTestApp(Scaffold(body: Column(children: [PlaceSummaryLine(ping: ping), PlaceSummaryLine(ping: old)]))),
    ));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('freshness-fresh')), findsOneWidget);
    expect(find.byKey(const ValueKey('freshness-stale')), findsOneWidget);
    expect(find.byIcon(Icons.schedule), findsOneWidget);
    expect(find.text('Updated 2 hours ago'), findsOneWidget);
    expect(isStaleFix(null, now), isTrue, reason: 'an unknown time is not presented as current');
  });

  testWidgets('tapping the card place line runs its action (the dashboard opens the Location tab)', (tester) async {
    var taps = 0;
    await tester.pumpWidget(ProviderScope(
      overrides: overrides(marks: const [Placemark(locality: 'Dubai')]),
      child: localizedTestApp(Scaffold(body: PlaceSummaryLine(ping: ping, onTap: () => taps++))),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('placeLine')));
    expect(taps, 1);
    expect(tester.getSize(find.byKey(const ValueKey('placeLine'))).height, greaterThanOrEqualTo(48));
  });

  testWidgets('the child screen can open straight on the Location tab', (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [apiClientProvider.overrideWithValue(FakeApiClient(standardRoutes())), ...overrides()],
      child: localizedTestApp(const ChildDetailScreen(childId: 'child-1', initialTab: ChildDetailScreen.locationTab)),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Locate now'), findsOneWidget);
  });

  test('zoom keeps the accuracy circle readable', () {
    expect(ChildLocationMap.zoomFor(18), 16);
    expect(ChildLocationMap.zoomFor(150), 15);
    expect(ChildLocationMap.zoomFor(800), 13.5);
    expect(ChildLocationMap.zoomFor(5000), 12);
  });

  testWidgets('the profile Location tab shows a map card, the place and Open in Maps, not the placeholder',
      (tester) async {
    final api = FakeApiClient({
      ...standardRoutes(),
      'GET /v1/location/child-1/latest': (_) => {
            'latest': {
              'deviceId': 'dev-1',
              'lat': ping.lat,
              'lng': ping.lng,
              'accuracyM': ping.accuracyM,
              'timestamp': ping.timestamp!.toUtc().toIso8601String(),
            },
          },
    });
    await tester.pumpWidget(ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        ...overrides(marks: const [Placemark(subLocality: 'Al Barsha', locality: 'Dubai')]),
      ],
      child: localizedTestApp(const ChildDetailScreen(childId: 'child-1')),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Location'));
    await tester.pumpAndSettle();

    expect(find.byType(ChildLocationMap), findsOneWidget);
    expect(find.text('Al Barsha, Dubai'), findsWidgets);
    expect(find.text('Open in Maps'), findsOneWidget);
    expect(find.text('Map preview'), findsNothing, reason: 'the grey placeholder is gone');
    expect(find.textContaining('25.11318'), findsNothing);
  });

  testWidgets('a failed lookup is not cached: it retries while shown, and a later success shows the place',
      (tester) async {
    var calls = 0;
    await tester.pumpWidget(ProviderScope(
      overrides: [
        clockProvider.overrideWithValue(() => now),
        placemarkLookupProvider.overrideWithValue((lat, lng, locale) async {
          calls++;
          if (calls == 1) throw Exception('offline');
          return const [Placemark(subLocality: 'Al Barsha', locality: 'Dubai')];
        }),
      ],
      child: localizedTestApp(Scaffold(body: PlaceSummaryLine(ping: ping))),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Address not available'), findsOneWidget);

    await tester.pump(kPlaceNameRetryAfter);
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(find.text('Al Barsha, Dubai'), findsOneWidget);
  });

  testWidgets('a failed lookup is dropped once nothing shows it, so reopening asks again', (tester) async {
    var calls = 0;
    final container = ProviderContainer(overrides: [
      clockProvider.overrideWithValue(() => now),
      placemarkLookupProvider.overrideWithValue((lat, lng, locale) async {
        calls++;
        if (calls == 1) throw Exception('offline');
        return const [Placemark(locality: 'Dubai')];
      }),
    ]);
    Widget app(bool show) => UncontrolledProviderScope(
          container: container,
          child: localizedTestApp(Scaffold(body: show ? PlaceSummaryLine(ping: ping) : const SizedBox())),
        );
    await tester.pumpWidget(app(true));
    await tester.pumpAndSettle();
    expect(find.text('Address not available'), findsOneWidget);
    await tester.pumpWidget(app(false));
    await tester.pumpAndSettle();
    await tester.pumpWidget(app(true));
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(find.text('Dubai'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    container.dispose();
  });

  testWidgets('a found name is cached for a bounded time, then looked up again', (tester) async {
    var calls = 0;
    final container = ProviderContainer(overrides: [
      clockProvider.overrideWithValue(() => now),
      placemarkLookupProvider.overrideWithValue((lat, lng, locale) async {
        calls++;
        return const [Placemark(locality: 'Dubai')];
      }),
    ]);
    Widget app(bool show) => UncontrolledProviderScope(
          container: container,
          child: localizedTestApp(Scaffold(body: show ? PlaceSummaryLine(ping: ping) : const SizedBox())),
        );
    await tester.pumpWidget(app(true));
    await tester.pumpAndSettle();
    await tester.pumpWidget(app(false));
    await tester.pumpAndSettle();
    await tester.pumpWidget(app(true));
    await tester.pumpAndSettle();
    expect(calls, 1, reason: 'reopened within the cache time: no new lookup');
    await tester.pumpWidget(app(false));
    await tester.pump(kPlaceNameCacheFor + const Duration(minutes: 1));
    await tester.pumpWidget(app(true));
    await tester.pumpAndSettle();
    expect(calls, 2, reason: 'the cached name expired');
    await tester.pumpWidget(const SizedBox());
    container.dispose();
  });

  testWidgets('the profile map follows a new fix; after a manual pan a recentre button brings it back',
      (tester) async {
    final far = LocationPing(deviceId: 'dev-1', lat: 25.2048, lng: 55.2708, accuracyM: 18, timestamp: now);
    final farther = LocationPing(deviceId: 'dev-1', lat: 25.0657, lng: 55.1713, accuracyM: 18, timestamp: now);
    final current = ValueNotifier(ping);
    addTearDown(current.dispose);
    await tester.pumpWidget(ProviderScope(
      overrides: overrides(marks: const [Placemark(locality: 'Dubai')]),
      child: localizedTestApp(Scaffold(
        body: ValueListenableBuilder<LocationPing>(
          valueListenable: current,
          builder: (_, p, __) => SizedBox(width: 360, height: 270, child: ChildLocationMap(ping: p, childName: 'Alex')),
        ),
      )),
    ));
    await tester.pump(const Duration(milliseconds: 100));
    MapCamera camera() => tester.widget<FlutterMap>(find.byType(FlutterMap)).mapController!.camera;
    expect(camera().center.latitude, closeTo(ping.lat, 1e-6));

    current.value = far;
    await tester.pump(const Duration(milliseconds: 100));
    expect(camera().center.latitude, closeTo(far.lat, 1e-6), reason: 'a new fix recentres the same mounted map');
    expect(find.byKey(const ValueKey('recentreMap')), findsNothing);

    await tester.drag(find.byType(FlutterMap), const Offset(120, 80));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byKey(const ValueKey('recentreMap')), findsOneWidget);

    current.value = farther;
    await tester.pump(const Duration(milliseconds: 100));
    expect(camera().center.latitude, isNot(closeTo(farther.lat, 1e-3)), reason: 'following pauses after a manual pan');

    await tester.tap(find.byKey(const ValueKey('recentreMap')));
    await tester.pump(const Duration(milliseconds: 100));
    expect(camera().center.latitude, closeTo(farther.lat, 1e-6));
    expect(camera().center.longitude, closeTo(farther.lng, 1e-6));
    expect(find.byKey(const ValueKey('recentreMap')), findsNothing);
  });
}
