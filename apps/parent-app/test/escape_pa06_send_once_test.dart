import 'dart:async';

import 'package:familyshield_parent/api/models.dart';
import 'package:familyshield_parent/core/command_in_flight.dart';
import 'package:familyshield_parent/features/children/child_detail_screen.dart';
import 'package:familyshield_parent/features/map/family_map_screen.dart';
import 'package:familyshield_parent/l10n/app_localizations.dart';
import 'package:familyshield_parent/providers/auth_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_api_client.dart';
import 'test_app.dart';

/// Child-escape catalogue PA06 (#738, `docs/testing/CHILD-ESCAPE-CATALOGUE.md` row PA06):
///
/// > Double-tap ring/stop, lock/unlock fast, send while offline — exactly the last intent wins on the
/// > child; history shows each command once.
///
/// The parent app used to post every tap, so a double tap queued the command twice. These rows pin the
/// guard that makes one intent one POST, and the two ways it must *not* over-reach: a different command
/// in the same instant still goes, and a failed POST does not wedge the control.
///
/// Mutants (each must turn exactly the named rows red):
/// - drop the `beginCommandSend` early return in child detail or the map sheet → rows 1 and 4 post twice;
/// - key the guard by device alone instead of device + command → row 2 loses the unlock;
/// - drop the `endCommandSend` release in child detail → row 3 never retries after a 503, and row 4 gets
///   no POST at all: the claim a failed ring left behind is still held when the map tries the same command.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final en = lookupAppLocalizations(const Locale('en'));

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  /// A route that leaves each POST outstanding until the test completes it, so "tapped again while the
  /// first one is still in flight" is a real state rather than a race the fake resolves first.
  final pending = <Completer<Object?>>[];

  FakeDeferred hold(RecordedRequest request) {
    final completer = Completer<Object?>();
    pending.add(completer);
    return FakeDeferred(completer.future);
  }

  void releaseAll() {
    for (final completer in pending) {
      if (!completer.isCompleted) completer.complete({'status': 'pending'});
    }
    pending.clear();
  }

  /// Taps, then gives the Dio interceptor enough frames to record the request. The POST itself stays
  /// outstanding (that is the point), so `pumpAndSettle` is not usable here — it returns only when
  /// nothing is scheduled, and a held response is still scheduled.
  Future<void> tapAndPump(WidgetTester tester, Finder finder) async {
    await tester.tap(finder);
    // A bare pump() does not advance the fake clock, and the request only reaches the interceptor on a
    // timed pump — so a recorded request is what proves the tap posted, not that the type-checked code ran.
    await tester.pump(const Duration(milliseconds: 20));
    await tester.pump(const Duration(milliseconds: 20));
  }

  /// A test may not leave a claim behind: the `finally` must have released every sender by the time the
  /// body ends. Asserted in the body, where the tree is still alive to settle the awaits.
  void expectNoClaimsLeft() {
    expect(commandsInFlightCount, 0, reason: 'every sender must release its claim, even after a failure');
  }

  tearDown(releaseAll);

  Future<void> pumpDetail(WidgetTester tester, FakeApiClient api) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(ProviderScope(
      overrides: [apiClientProvider.overrideWithValue(api)],
      child: localizedTestApp(const ChildDetailScreen(childId: 'child-1')),
    ));
    await tester.pumpAndSettle();
  }

  FakeApiClient detailApi() => FakeApiClient({
        ...standardRoutes(),
        'POST /v1/devices/dev-1/command': hold,
      });

  testWidgets('a double tap on Ring in child detail posts one command, not two', (tester) async {
    final api = detailApi();
    await pumpDetail(tester, api);

    await tapAndPump(tester, find.text(en.ring));
    expect(api.calls('POST', '/v1/devices/dev-1/command'), hasLength(1),
        reason: 'the first tap must post; a guard that blocks it makes the row pass for the wrong reason');

    await tapAndPump(tester, find.text(en.ring));
    releaseAll();
    await tester.pumpAndSettle();

    expect(api.calls('POST', '/v1/devices/dev-1/command'), hasLength(1),
        reason: 'the second tap is the same intent while the first POST is outstanding');
  });

  testWidgets('lock then unlock in the same instant still sends both commands', (tester) async {
    final api = detailApi();
    await pumpDetail(tester, api);

    await tapAndPump(tester, find.text(en.lock));
    await tapAndPump(tester, find.text(en.unlock));
    releaseAll();
    await tester.pumpAndSettle();

    final sent = [for (final r in api.calls('POST', '/v1/devices/dev-1/command')) r.body['command']];
    expect(sent, ['lock', 'unlock'],
        reason: 'two different intents in the same instant are not a double tap; a device-wide guard drops the unlock');
  });

  testWidgets('a refused POST releases the guard, so a retry is sent', (tester) async {
    var calls = 0;
    final api = FakeApiClient({
      ...standardRoutes(),
      'POST /v1/devices/dev-1/command': (_) {
        calls++;
        return calls == 1 ? const FakeHttpError(503, {'error': 'unavailable'}) : {'status': 'pending'};
      },
    });
    await pumpDetail(tester, api);

    await tester.tap(find.text(en.ring));
    await tester.pumpAndSettle();
    await tester.tap(find.text(en.ring));
    await tester.pumpAndSettle();

    expect(api.calls('POST', '/v1/devices/dev-1/command'), hasLength(2),
        reason: 'a failed ring must be retryable; releasing only on success leaves the button dead for the session');
    expectNoClaimsLeft();
  });

  testWidgets('a double tap on Ring in the map sheet posts one command, not two', (tester) async {
    final api = FakeApiClient({
      ...standardRoutes(),
      'POST /v1/devices/dev-1/command': hold,
    });
    await tester.pumpWidget(ProviderScope(
      overrides: [apiClientProvider.overrideWithValue(api)],
      child: localizedTestApp(Scaffold(
        body: ChildMapSheet(
          child: const Child(id: 'child-1', familyId: 'fam-1', displayName: 'Alex', birthYear: 2013),
          ping: LocationPing(deviceId: 'dev-1', lat: 25.3, lng: 51.5, timestamp: DateTime.utc(2026, 11, 22, 9)),
          device: const Device(
            id: 'dev-1',
            childId: 'child-1',
            platform: 'android',
            model: 'Pixel 7',
            osVersion: '14',
            status: 'online',
            batteryPct: 80,
          ),
        ),
      )),
    ));
    await tester.pumpAndSettle();

    await tapAndPump(tester, find.text(en.familyMapRing));
    await tapAndPump(tester, find.text(en.familyMapRing));
    releaseAll();
    await tester.pumpAndSettle();

    expect(api.calls('POST', '/v1/devices/dev-1/command'), hasLength(1),
        reason: 'the map sends commands too, and the guard is shared with child detail');
  });
}
