import 'package:familyshield_parent/api/models.dart';
import 'package:familyshield_parent/features/dashboard/child_location_row.dart';
import 'package:familyshield_parent/features/map/family_map_screen.dart';
import 'package:familyshield_parent/providers/auth_provider.dart';
import 'package:familyshield_parent/providers/clock_provider.dart';
import 'package:familyshield_parent/providers/family_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_api_client.dart';
import 'test_app.dart';

const _child = Child(
    id: 'child-1', familyId: 'family-1', displayName: 'Alex', birthYear: 2014);

Geofence _place(String label, {double radius = 100, double latitude = 34}) =>
    Geofence(
      id: label,
      childId: _child.id,
      label: label,
      lat: latitude,
      lng: 12,
      radiusM: radius,
    );

LocationPing _fix(DateTime time, {double accuracy = 8, double latitude = 34}) =>
    LocationPing(
      deviceId: 'device-1',
      lat: latitude,
      lng: 12,
      accuracyM: accuracy,
      timestamp: time,
    );

void main() {
  final time = DateTime.utc(2026, 11, 21, 12);

  test('chooses the most specific place that contains the accuracy circle', () {
    final fix = _fix(time);
    expect(
      savedPlaceForFix(
          fix, [_place('Campus', radius: 400), _place('School')], time),
      (name: 'School', at: true),
    );
  });

  test('distinguishes an approximate boundary fix from a distant or old fix',
      () {
    final campus = [_place('School')];
    expect(
      savedPlaceForFix(_fix(time, latitude: 34.0009), campus, time),
      (name: 'School', at: false),
    );
    expect(
        savedPlaceForFix(_fix(time, latitude: 34.010), campus, time), isNull);
    expect(savedPlaceForFix(_fix(time, accuracy: 0), campus, time), isNull);
    expect(
        savedPlaceForFix(
            _fix(time), campus, time.add(const Duration(hours: 1))),
        isNull);
  });

  test('the native map fallback retains both unrounded coordinates', () {
    const lat = 34.000912345;
    const lng = 12.000345678;
    final apple = platformMapPinUri(TargetPlatform.iOS,
        lat: lat, lng: lng, label: 'Map preview');
    expect(apple.queryParameters['ll'], '$lat,$lng');
    final android = platformMapPinUri(TargetPlatform.android,
        lat: lat, lng: lng, label: 'Map preview');
    expect(android.queryParameters['q'], '$lat,$lng(Map preview)');
  });

  Future<void> pumpRow(WidgetTester tester,
      {required LocationPing fix, bool refused = false}) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(FakeApiClient(standardRoutes())),
        clockProvider.overrideWithValue(tester.binding.clock.now),
        familyProvider.overrideWith((_) async =>
            throw StateError('Map data omitted from this fixture')),
      ],
      child: localizedTestApp(
        Scaffold(
            body: ChildLocationRow(
                child: _child,
                fix: fix,
                places: [_place('Home')],
                refused: refused)),
        theme: ThemeData(platform: TargetPlatform.android),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('saved place action preserves the exact fix on the family map',
      (tester) async {
    final recent = _fix(
        tester.binding.clock.now().subtract(const Duration(minutes: 1)),
        latitude: 34.000012345);
    await pumpRow(tester, fix: recent);

    expect(find.text('At Home'), findsOneWidget);
    expect(find.textContaining('34.0000'), findsNothing);
    await tester.tap(find.text('At Home'));
    await tester.pumpAndSettle();
    final map = tester.widget<FamilyMapScreen>(find.byType(FamilyMapScreen));
    expect(map.focus?.position.latitude, recent.lat);
    expect(map.focus?.position.longitude, recent.lng);
    expect(map.focus?.accuracyM, recent.accuracyM);
    expect(map.focus?.isAlert, isFalse);
  });

  testWidgets('saved place label expires on screen and a new fix resets it',
      (tester) async {
    final clock = tester.binding.clock;
    await pumpRow(tester,
        fix: _fix(clock.now().subtract(const Duration(minutes: 14))));
    expect(find.text('At Home'), findsOneWidget);

    await tester.pump(const Duration(seconds: 30));
    await pumpRow(tester,
        fix: _fix(clock.now().subtract(const Duration(minutes: 13))));
    expect(find.text('At Home'), findsOneWidget);

    await tester.pump(const Duration(minutes: 1));
    expect(find.text('At Home'), findsOneWidget);
    await tester.pump(const Duration(minutes: 1));
    expect(find.text('At Home'), findsNothing);
    expect(find.text('Show on map'), findsOneWidget);
    expect(find.byKey(const ValueKey('child-location-map-child-1')),
        findsOneWidget);
  });

  testWidgets(
      'a permission refusal removes the tap even if an old fix was cached',
      (tester) async {
    await pumpRow(tester, fix: _fix(tester.binding.clock.now()), refused: true);
    expect(
        find.byKey(const ValueKey('child-location-map-child-1')), findsNothing);
    expect(find.textContaining('Home'), findsNothing);
    expect(find.byType(FamilyMapScreen), findsNothing);
  });
}
