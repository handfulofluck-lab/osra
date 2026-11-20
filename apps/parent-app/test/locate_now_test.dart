import 'package:familyshield_parent/core/ltr_isolate.dart';
import 'package:familyshield_parent/features/children/child_detail_screen.dart';
import 'package:familyshield_parent/providers/auth_provider.dart';
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

    // The action lives on the Location tab, next to the state a parent reads when there is no position.
    await tester.tap(find.text('Location'));
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
            // The agent's real vocabulary (`command_messages.dart:31`), not a token I invented: the
            // first version of this row used a made-up reason and silently exercised the fallback.
            'reason': 'background_location_missing',
          },
    });
    await tester.pumpWidget(ProviderScope(
      overrides: [apiClientProvider.overrideWithValue(api)],
      child: localizedTestApp(const ChildDetailScreen(childId: 'child-1')),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Location'));
    await tester.pumpAndSettle();

    final locate = find.text('Locate now');
    await tester.ensureVisible(locate);
    await tester.tap(locate);
    await tester.pumpAndSettle();

    expect(find.textContaining('was not sent'), findsOneWidget,
        reason: 'a refusal must say it was not sent, not that it was queued');
    expect(find.textContaining('queued for'), findsNothing);
  });

  /// Cross-family review F2 (`7039886009`): a child can have more than one phone. The first version of this PR
  /// wired one unlabelled button to `devices.first`, so an iPhone 13 would have been queried and the Galaxy Tab
  /// beside it could never be asked — with nothing on screen saying which phone the tap would reach.
  testWidgets('with two phones there is one locate button each, naming the phone',
      (tester) async {
    final api = FakeApiClient({
      ...standardRoutes(familyMe: familyMeMixedDevices()),
      'POST /v1/devices/dev-3/command': (_) => {'status': 'pending'},
    });
    await tester.pumpWidget(ProviderScope(
      overrides: [apiClientProvider.overrideWithValue(api)],
      child: localizedTestApp(const ChildDetailScreen(childId: 'child-1')),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Location'));
    await tester.pumpAndSettle();

    final second = find.byKey(const ValueKey('locateNow-dev-3'));
    expect(second, findsOneWidget, reason: 'the second device needs its own action');
    expect(find.text('Locate now (${ltrIsolate('Galaxy Tab')})'), findsOneWidget,
        reason: 'the label names the phone, so the parent knows which one is asked');

    await tester.ensureVisible(second);
    await tester.tap(second);
    await tester.pumpAndSettle();

    final commands =
        api.requests.where((request) => request.method == 'POST').toList();
    expect(commands.single.path, '/v1/devices/dev-3/command',
        reason: 'an unlabelled button to devices.first is the bug this row pins');
    expect(commands.single.body, {'command': 'locate_now'});
  });

  /// Cross-family review F1/`M3` (`7039886009`): the server answers `{status: "pending"}` **before** the phone has
  /// the command, so re-reading `/latest` at that moment returns the same 404 or the same older fix. The first
  /// version did exactly that, and deleting the line left all six checks green — this row is what makes the
  /// behaviour visible either way. The fresh fix arrives through the `/v1/ws` `location` message instead, which
  /// `realtime_refresh_test.dart:85` already covers.
  testWidgets('a queued answer does not re-read the location it could not have changed',
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

    await tester.tap(find.text('Location'));
    await tester.pumpAndSettle();

    int latestReads() => api.calls('GET', '/v1/location/child-1/latest').length;
    final before = latestReads();

    final locate = find.text('Locate now');
    await tester.ensureVisible(locate);
    await tester.tap(locate);
    await tester.pumpAndSettle();

    expect(latestReads(), before,
        reason: 'queueing the command cannot have produced a new fix, so asking for one is a wasted read; '
            'the position arrives on the location message from /v1/ws');
  });
}
