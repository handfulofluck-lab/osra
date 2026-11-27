import 'package:familyshield_parent/features/children/child_detail_screen.dart';
import 'package:familyshield_parent/providers/auth_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_api_client.dart';
import 'test_app.dart';

/// #1167 (Codex's 26 Nov preflight): the parent card stayed on "Pausing…" after the child applied Pause, and only
/// a pull-to-refresh exposed Resume. The app learns "the handset acted" from one realtime frame, and the server
/// publishes that frame best-effort, so a lost frame used to strand the card with no recovery path of its own.
/// While a pause/resume command is waiting, the open card re-reads that device's history on a bounded backoff.
/// This row holds both transitions it has to carry, with the card never left and nothing pulled.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('an open card settles Pause and then Resume when the handset acknowledges', (tester) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final pauseAt = DateTime.now().subtract(const Duration(minutes: 2));
    final resumeAt = DateTime.now();
    var items = <Map<String, dynamic>>[
      commandJson('c1', 'pause', 'delivered', pauseAt),
    ];
    final api = FakeApiClient({
      ...standardRoutes(),
      'GET /v1/devices/dev-1/commands/history': (_) => {'items': items},
    });

    await tester.pumpWidget(ProviderScope(
      overrides: [apiClientProvider.overrideWithValue(api)],
      child: localizedTestApp(const ChildDetailScreen(childId: 'child-1')),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Pausing…'), findsOneWidget,
        reason: 'the pause reached the phone but has not been acknowledged');

    items = [commandJson('c1', 'pause', 'acked', pauseAt)];
    // One tick of the bounded backoff: 61 s covers every step of it, so the row does not depend on which step the
    // opening settle happened to reach.
    await tester.pump(const Duration(seconds: 61));
    await tester.pumpAndSettle();
    expect(find.text('Resume device'), findsOneWidget,
        reason: 'the acknowledgement arrives on the card\'s own re-read, with no pull and no navigation');

    await tester.tap(find.byKey(const ValueKey('deviceAction-resume-dev-1')));
    items = [
      commandJson('c2', 'resume', 'delivered', resumeAt),
      commandJson('c1', 'pause', 'acked', pauseAt),
    ];
    await tester.pumpAndSettle();
    expect(find.text('Resuming…'), findsOneWidget,
        reason: 'the resume is queued and the phone has not confirmed it yet');

    items = [
      commandJson('c2', 'resume', 'acked', resumeAt),
      commandJson('c1', 'pause', 'acked', pauseAt),
    ];
    await tester.pump(const Duration(seconds: 61));
    await tester.pumpAndSettle();
    expect(find.text('Pause device'), findsOneWidget,
        reason: 'the acknowledged resume returns the card to Pause device on its own');
  });
}
