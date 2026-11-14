import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:familyshield_parent/api/models.dart';
import 'package:familyshield_parent/features/children/child_detail_screen.dart';
import 'package:familyshield_parent/features/map/family_map_screen.dart';
import 'package:familyshield_parent/providers/auth_provider.dart';

import 'fake_api_client.dart';
import 'test_app.dart';

void main() {
  const ping = LocationPing(deviceId: 'dev-1', lat: 25.3, lng: 51.5);
  const device = Device(
    id: 'dev-1', childId: 'child-1', platform: 'android', model: 'Pixel 7', osVersion: '14',
    status: 'online', batteryPct: 80,
  );

  FakeApiClient apiWithRing(String? ringId) => FakeApiClient({
        ...standardRoutes(),
        'GET /v1/devices/dev-1/commands/history': (_) => {
          'items': [
            if (ringId != null)
              {'id': ringId, 'deviceId': 'dev-1', 'type': 'ring', 'status': 'acked'},
          ],
        },
      });

  Future<void> pump(WidgetTester tester, Widget screen, FakeApiClient api) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [apiClientProvider.overrideWithValue(api)],
      child: localizedTestApp(Scaffold(body: screen)),
    ));
    await tester.pumpAndSettle();
  }

  Map<String, dynamic> postedCommand(FakeApiClient api) =>
      api.requests.singleWhere((request) => request.method == 'POST' && request.path == '/v1/devices/dev-1/command').body;

  testWidgets('child detail stop_ring includes the latest ring id', (tester) async {
    final api = apiWithRing('ring-1');
    await pump(tester, const ChildDetailScreen(childId: 'child-1'), api);
    await tester.tap(find.text('Stop ringing'));
    await tester.pumpAndSettle();
    expect(postedCommand(api), {'command': 'stop_ring', 'payload': {'ringId': 'ring-1'}});
  });

  testWidgets('map stop_ring includes the latest ring id', (tester) async {
    final api = apiWithRing('ring-1');
    await pump(tester, const ChildMapSheet(child: Child(id: 'child-1', familyId: 'fam-1', displayName: 'Alex', birthYear: 2013), ping: ping, device: device), api);
    await tester.tap(find.text('Stop ringing'));
    await tester.pumpAndSettle();
    expect(postedCommand(api), {'command': 'stop_ring', 'payload': {'ringId': 'ring-1'}});
  });

  testWidgets('without ring history stop_ring keeps the current-ring meaning', (tester) async {
    final api = apiWithRing(null);
    await pump(tester, const ChildMapSheet(child: Child(id: 'child-1', familyId: 'fam-1', displayName: 'Alex', birthYear: 2013), ping: ping, device: device), api);
    await tester.tap(find.text('Stop ringing'));
    await tester.pumpAndSettle();
    expect(postedCommand(api), {'command': 'stop_ring'});
  });
}
