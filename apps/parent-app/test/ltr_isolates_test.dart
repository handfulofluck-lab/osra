import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:familyshield_parent/api/models.dart';
import 'package:familyshield_parent/features/children/child_detail_screen.dart';
import 'package:familyshield_parent/features/dashboard/dashboard_screen.dart';
import 'package:familyshield_parent/features/map/family_map_screen.dart';
import 'package:familyshield_parent/features/social/social_screen.dart';
import 'package:familyshield_parent/l10n/app_localizations.dart';
import 'package:familyshield_parent/providers/auth_provider.dart';
import 'package:familyshield_parent/providers/family_provider.dart';
import 'package:familyshield_parent/providers/social_provider.dart';
import 'package:familyshield_parent/providers/world_class_provider.dart';

import 'fake_api_client.dart';
import 'test_app.dart';

const _child = Child(id: 'child-1', familyId: 'fam-1', displayName: 'Alex', birthYear: 2013);
const _ping = LocationPing(deviceId: 'dev-1', lat: 25.2769, lng: 51.5211, accuracyM: 8);

void main() {
  final arabic = lookupAppLocalizations(const Locale('ar'));

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  Future<void> pumpArabic(WidgetTester tester, Widget home, {List<Override> overrides = const []}) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(FakeApiClient(standardRoutes())),
        ...overrides,
      ],
      child: localizedTestApp(
        Scaffold(body: home),
        locale: const Locale('ar'),
        textDirection: TextDirection.rtl,
      ),
    ));
    await tester.pumpAndSettle();
  }

  Future<void> openLocationTab(WidgetTester tester, List<LocationPing> history) async {
    await pumpArabic(
      tester,
      const ChildDetailScreen(childId: 'child-1'),
      overrides: [
        locationProvider('child-1').overrideWith((ref) => _ping),
        locationHistoryProvider.overrideWith((ref, childId) => history),
      ],
    );
    await tester.tap(find.text(arabic.tabLocation));
    await tester.pumpAndSettle();
  }

  // Mutant: remove any one of the six ltrIsolate calls; its corresponding row must go red.
  testWidgets('latest location isolates both coordinates in Arabic RTL', (tester) async {
    await openLocationTab(tester, const []);

    expect(find.text('\u206625.276900, 51.521100\u2069'), findsOneWidget);
  });

  testWidgets('location history without a time isolates both coordinates', (tester) async {
    await openLocationTab(tester, const [_ping]);

    expect(
      find.text('\u206625.27690, 51.52110\u2069 · ${arabic.accuracyUnknown}'),
      findsOneWidget,
    );
  });

  testWidgets('location history with a time isolates both coordinates', (tester) async {
    final ping = LocationPing(
      deviceId: 'dev-1',
      lat: 25.2769,
      lng: 51.5211,
      accuracyM: 8,
      timestamp: DateTime.utc(2026, 11, 13, 9, 30),
    );
    await openLocationTab(tester, [ping]);

    expect(find.textContaining('\u206625.27690, 51.52110\u2069 · ±8 m'), findsOneWidget);
  });

  testWidgets('dashboard child card isolates both coordinates in Arabic RTL', (tester) async {
    await pumpArabic(
      tester,
      const DashboardScreen(),
      overrides: [locationProvider('child-1').overrideWith((ref) => _ping)],
    );

    expect(find.text('\u206625.2769, 51.5211\u2069'), findsOneWidget);
  });

  testWidgets('map marker sheet isolates both coordinates in Arabic RTL', (tester) async {
    await pumpArabic(tester, const ChildMapSheet(child: _child, ping: _ping));

    expect(find.text('\u206625.276900, 51.521100\u2069'), findsOneWidget);
  });

  testWidgets('call and SMS timeline isolates a spaced phone number in Arabic RTL', (tester) async {
    final event = ActivityEvent(
      id: 'call-1',
      type: 'call',
      payload: const {'number': '+971 50 123 4567', 'durationSec': 65, 'direction': 'outgoing'},
      ts: DateTime.utc(2026, 11, 13, 9, 30),
    );
    await pumpArabic(
      tester,
      const CallsSmsSection(childId: 'child-1'),
      overrides: [activityProvider('child-1').overrideWith((ref) => [event])],
    );

    expect(find.text('\u2066+971 50 123 4567\u2069'), findsOneWidget);
  });
}
