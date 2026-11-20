import 'package:familyshield_parent/api/models.dart';
import 'package:familyshield_parent/features/children/child_detail_screen.dart';
import 'package:familyshield_parent/features/map/family_map_screen.dart';
import 'package:familyshield_parent/providers/auth_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_api_client.dart';
import 'test_app.dart';

void main() {
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  const child = Child(
      id: 'child-1', familyId: 'fam-1', displayName: 'Alex', birthYear: 2013);
  const device = Device(
    id: 'dev-1',
    childId: 'child-1',
    platform: 'android',
    model: 'Pixel 7a',
    osVersion: '14',
    status: 'online',
    batteryPct: 55,
  );
  const stopLabel = 'Stop ringing';
  const deviceCommandPath = '/v1/devices/dev-1/command';

  for (final (surface, screen) in [
    ('device card', const ChildDetailScreen(childId: 'child-1')),
    (
      'map callout',
      const Scaffold(
        body: ChildMapSheet(
          child: child,
          ping: LocationPing(deviceId: 'dev-1', lat: 0, lng: 0),
          device: device,
        ),
      ),
    ),
  ]) {
    testWidgets('$surface can stop a ring on the selected device',
        (tester) async {
      final now = DateTime.now();
      const ringId = 'ring-fixture';
      final api = FakeApiClient({
        ...standardRoutes(),
        'GET /v1/devices/dev-1/commands/history': (_) => {
              'items': [
                commandJson(
                  ringId,
                  'ring',
                  'acked',
                  now.subtract(const Duration(seconds: 15)),
                  deliveredAt: now.subtract(const Duration(seconds: 14)),
                  ackedAt: now.subtract(const Duration(seconds: 13)),
                  result: {'status': 'ok'},
                ),
              ],
            },
        'POST $deviceCommandPath': (_) => {'status': 'pending'},
      });
      await tester.pumpWidget(ProviderScope(
        overrides: [apiClientProvider.overrideWithValue(api)],
        child: localizedTestApp(screen),
      ));
      await tester.pumpAndSettle();

      final stop = find.text(stopLabel);
      expect(stop, findsOneWidget);
      await tester.ensureVisible(stop);
      await tester.tap(stop);
      await tester.pumpAndSettle();

      final commands =
          api.requests.where((request) => request.method == 'POST');
      expect(commands.single.path, deviceCommandPath);
      expect(commands.single.body, {'command': 'stop_ring'});
      expect(
        find.text(
            'Stop ringing queued for Pixel 7a — the device has not confirmed it yet.'),
        findsOneWidget,
      );
    });
  }
}
