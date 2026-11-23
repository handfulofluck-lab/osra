import 'package:familyshield_parent/api/models.dart';
import 'package:familyshield_parent/features/children/child_detail_screen.dart';
import 'package:familyshield_parent/features/map/child_location_view.dart';
import 'package:familyshield_parent/providers/auth_provider.dart';
import 'package:familyshield_parent/providers/clock_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
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
}
