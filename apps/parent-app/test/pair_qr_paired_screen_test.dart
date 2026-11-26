import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:familyshield_parent/features/pairing/pair_qr_payload.dart';
import 'package:familyshield_parent/features/pairing/pair_qr_screen.dart';
import 'package:familyshield_parent/providers/auth_provider.dart';

import 'fake_api_client.dart';
import 'test_app.dart';

/// #1134 (Codex's Build 41 repro): after the phone gets its token, a **standalone** pairing screen — opened from
/// the child card or `/child/:id/pair` — used to stay on the scan instructions with nothing to press. The claim
/// watch already learns the phone is paired; these rows hold that the screen then ends and the parent can leave.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  const code = '482916';
  final now = DateTime.utc(2026, 1, 1, 12, 0, 0);

  FakeApiClient api(Map<String, dynamic> Function() claim) {
    final routes = standardRoutes();
    routes['POST /v1/devices/pair'] = (_) => {
          'code': code,
          'expiresAt': now.add(kPairCodeTtl).toUtc().toIso8601String(),
        };
    routes['GET /v1/devices/pair/$code/claim'] = (_) => claim();
    return FakeApiClient(routes);
  }

  /// Lets the fake-Dio zero-duration timer chains complete.
  Future<void> flushFakeHttp(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> pump(WidgetTester tester, FakeApiClient client, {Widget? screen}) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [apiClientProvider.overrideWithValue(client)],
      child: localizedTestApp(
        screen ?? PairingQrScreen(childId: 'child-1', clock: () => now),
      ),
    ));
    await flushFakeHttp(tester);
  }

  Future<void> nextClaimRead(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 2));
    await flushFakeHttp(tester);
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  }

  testWidgets('a paired claim ends the standalone screen instead of leaving the scan instructions', (tester) async {
    await pump(tester, api(() => {
          'status': 'paired',
          'claimId': 'c-1',
          'deviceName': "Sam's phone",
        }));
    await nextClaimRead(tester);

    expect(find.byKey(const ValueKey('pairPairedTitle')), findsOneWidget,
        reason: 'the parent is told the phone is paired and given a way out');
    expect(find.byKey(const ValueKey('pairPairedDone')), findsOneWidget);
    expect(find.textContaining('482916'), findsNothing,
        reason: 'a used code is dead: the screen no longer offers it');
    await unmount(tester);
  });

  testWidgets('a claim still pending leaves the code on screen', (tester) async {
    await pump(tester, api(() => {'status': 'pending', 'claimId': 'c-1', 'deviceName': "Sam's phone"}));
    await nextClaimRead(tester);

    expect(find.byKey(const ValueKey('pairPairedTitle')), findsNothing);
    expect(find.textContaining(code), findsWidgets, reason: 'the parent is still waiting for the phone');
    await unmount(tester);
  });

  testWidgets('Done leaves the screen, so the child card behind it is reachable', (tester) async {
    await pump(
      tester,
      api(() => {'status': 'paired', 'claimId': 'c-1', 'deviceName': "Sam's phone"}),
      screen: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
                builder: (_) => PairingQrScreen(childId: 'child-1', clock: () => now),
              )),
              child: const Text('open pairing'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open pairing'));
    await flushFakeHttp(tester);
    await nextClaimRead(tester);

    await tester.tap(find.byKey(const ValueKey('pairPairedDone')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('pairPairedTitle')), findsNothing);
    expect(find.text('open pairing'), findsOneWidget, reason: 'back where the parent came from');
    await unmount(tester);
  });

  testWidgets('the wizard keeps its own Continue flow and is not dismissed', (tester) async {
    await pump(
      tester,
      api(() => {'status': 'paired', 'claimId': 'c-1', 'deviceName': "Sam's phone"}),
      screen: PairingQrScreen(
        childId: 'child-1',
        clock: () => now,
        onboarding: true,
        onContinue: () {},
        onSkip: () {},
      ),
    );
    await nextClaimRead(tester);

    expect(find.byKey(const ValueKey('pairPairedTitle')), findsNothing,
        reason: 'onboarding advances through its own step, not by replacing the screen');
    await unmount(tester);
  });
}
