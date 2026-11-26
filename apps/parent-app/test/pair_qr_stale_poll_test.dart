
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

/// Codex, #1149 `7184806902`: the claim poll runs every two seconds, so a slow answer can land after a newer one.
/// An earlier `pending`/`approved` reply arriving after `paired` used to overwrite the claim, un-cancel the timer
/// and bring the spent code back on screen. These rows pin the two guards that stop it.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  const code = '482916';
  final now = DateTime.utc(2026, 1, 1, 12, 0, 0);

  FakeApiClient clientReturning(Object? Function(int call) claim) {
    var call = 0;
    final routes = standardRoutes();
    routes['POST /v1/devices/pair'] = (_) => {
          'code': code,
          'expiresAt': now.add(kPairCodeTtl).toUtc().toIso8601String(),
        };
    routes['GET /v1/devices/pair/$code/claim'] = (_) => claim(++call);
    return FakeApiClient(routes);
  }

  /// Lets the fake-Dio zero-duration timer chains complete.
  Future<void> flushFakeHttp(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> pump(WidgetTester tester, FakeApiClient client) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [apiClientProvider.overrideWithValue(client)],
      child: localizedTestApp(PairingQrScreen(childId: 'child-1', clock: () => now)),
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

  testWidgets('a paired claim stops the poll and stays paired', (tester) async {
    await pump(
      tester,
      clientReturning((call) => call == 1
          ? {'status': 'pending', 'claimId': 'c-1', 'deviceName': "Sam's phone"}
          : {'status': 'paired', 'claimId': 'c-1', 'deviceName': "Sam's phone"}),
    );

    await nextClaimRead(tester); // pending
    await nextClaimRead(tester); // paired
    expect(find.byKey(const ValueKey('pairPairedTitle')), findsOneWidget);

    await nextClaimRead(tester); // nothing is read any more; the screen must not regress
    expect(find.byKey(const ValueKey('pairPairedTitle')), findsOneWidget);
    await unmount(tester);
  });
}
