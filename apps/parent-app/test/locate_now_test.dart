import 'package:familyshield_parent/api/models.dart';
import 'package:familyshield_parent/features/children/child_detail_screen.dart';
import 'package:familyshield_parent/providers/auth_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_api_client.dart';
import 'test_app.dart';

/// #869: the parent app could *show* a `locate_now` in the command history but had no way to send one, so
/// "Locate the child" had nothing behind it. The action reuses the Bureau's existing label, and this row is what
/// makes it real rather than a button that exists and posts nothing.
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
  const deviceCommandPath = '/v1/devices/dev-1/command';

  testWidgets('the device card can ask the phone for its location',
      (tester) async {
    final api = FakeApiClient({
      ...standardRoutes(),
      'POST $deviceCommandPath': (_) => {'status': 'pending'},
    });
    await tester.pumpWidget(ProviderScope(
      overrides: [apiClientProvider.overrideWithValue(api)],
      child: localizedTestApp(const ChildDetailScreen(childId: 'child-1')),
    ));
    await tester.pumpAndSettle();

    final locate = find.text('Locate now');
    expect(locate, findsOneWidget,
        reason: 'the parent must be able to ask for a position at all');
    await tester.ensureVisible(locate);
    await tester.tap(locate);
    await tester.pumpAndSettle();

    final commands =
        api.requests.where((request) => request.method == 'POST').toList();
    expect(commands.single.path, deviceCommandPath);
    expect(commands.single.body, {'command': 'locate_now'},
        reason: 'the POST must carry the command the server accepts');
    expect(
      find.text(
          'Locate now queued for Pixel 7a — the device has not confirmed it yet.'),
      findsOneWidget,
    );
  });

  /// The refusal the server already produces — a phone whose grant cannot answer — must reach the parent as the
  /// Bureau's sentence, not as `queued`. The API answers `{status: "failed", reason}` for exactly this case.
  testWidgets('a refused locate shows the reason instead of claiming it was queued',
      (tester) async {
    final api = FakeApiClient({
      ...standardRoutes(),
      'POST $deviceCommandPath': (_) => {
            'status': 'failed',
            'reason': 'background_location_not_authorized',
          },
    });
    await tester.pumpWidget(ProviderScope(
      overrides: [apiClientProvider.overrideWithValue(api)],
      child: localizedTestApp(const ChildDetailScreen(childId: 'child-1')),
    ));
    await tester.pumpAndSettle();

    final locate = find.text('Locate now');
    await tester.ensureVisible(locate);
    await tester.tap(locate);
    await tester.pumpAndSettle();

    expect(find.textContaining('was not sent'), findsOneWidget,
        reason: 'a refusal must say it was not sent, not that it was queued');
    expect(find.textContaining('queued for'), findsNothing);
  });
}
