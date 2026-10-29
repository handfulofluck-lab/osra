import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:familyshield_parent/features/children/child_detail_screen.dart';
import 'package:familyshield_parent/features/pairing/pair_qr_payload.dart';
import 'package:familyshield_parent/features/pairing/pair_qr_screen.dart';
import 'package:familyshield_parent/providers/auth_provider.dart';

import 'fake_api_client.dart';
import 'test_app.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  /// The server's TTL (services/api/src/routes/devices.ts) and a fixed clock so
  /// the countdown is deterministic across runs.
  var currentNow = DateTime.utc(2026, 1, 1, 12, 0, 0);

  setUp(() => currentNow = DateTime.utc(2026, 1, 1, 12, 0, 0));

  FakeApiClient pairingApi(
      {List<String> codes = const ['482916'],
      Map<String, FakeRoute> extra = const {}}) {
    var call = 0;
    final routes = standardRoutes();
    routes['POST /v1/devices/pair'] = (_) {
      final code = codes[call.clamp(0, codes.length - 1)];
      call++;
      return {
        'code': code,
        'expiresAt': currentNow.add(kPairCodeTtl).toUtc().toIso8601String(),
      };
    };
    routes.addAll(extra);
    return FakeApiClient(routes);
  }

  Future<void> pumpScreen(WidgetTester tester, FakeApiClient api,
      {Size? surface}) async {
    if (surface != null) {
      tester.view.physicalSize = surface;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
    }
    await tester.pumpWidget(ProviderScope(
      overrides: [apiClientProvider.overrideWithValue(api)],
      child: localizedTestApp(
        PairingQrScreen(childId: 'child-1', clock: () => currentNow),
      ),
    ));
    await flushFakeHttp(tester);
  }

  /// Disposes the screen (and its 1 s countdown timer) before the test ends.
  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  }

  testWidgets('POSTs /v1/devices/pair and shows the QR payload plus the code',
      (tester) async {
    final api = pairingApi();
    await pumpScreen(tester, api);

    expect(api.calls('POST', '/v1/devices/pair'), hasLength(1));
    expect(api.calls('POST', '/v1/devices/pair').single.body['childId'],
        'child-1');

    final qr =
        tester.widget<PairingQr>(find.byKey(const ValueKey('pairingQr')));
    final decoded = PairQrPayload.decode(qr.data);
    expect(decoded.code, '482916');
    expect(decoded.apiBaseUrl, 'http://testserver');
    expect(find.text('482916'), findsOneWidget);
    expect(find.text('Expires in 10:00'), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('the countdown reaches zero and disables the QR, code and copy',
      (tester) async {
    final api = pairingApi();
    await pumpScreen(tester, api);
    expect(find.byKey(const ValueKey('pairingQr')), findsOneWidget);

    // Walk the injected clock to the server expiry, then let the 1 s timer run.
    currentNow = currentNow.add(kPairCodeTtl);
    await tester.pump(const Duration(seconds: 1));

    expect(find.byKey(const ValueKey('pairingExpired')), findsOneWidget);
    expect(find.text('Expires in 00:00'), findsOneWidget);
    expect(find.byKey(const ValueKey('pairingQr')), findsNothing);
    expect(find.byKey(const ValueKey('pairingCode')), findsNothing);

    final copy = tester
        .widget<OutlinedButton>(find.byKey(const ValueKey('pairingCopy')));
    expect(copy.onPressed, isNull);
    final regenerate = tester
        .widget<FilledButton>(find.byKey(const ValueKey('pairingRegenerate')));
    expect(regenerate.onPressed, isNotNull);

    await unmount(tester);
  });

  testWidgets('Regenerate POSTs the pair request again and shows the new code',
      (tester) async {
    final api = pairingApi(codes: const ['482916', '482917']);
    await pumpScreen(tester, api);
    expect(find.text('482916'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('pairingRegenerate')));
    await flushFakeHttp(tester);

    expect(api.calls('POST', '/v1/devices/pair'), hasLength(2));
    expect(find.text('482917'), findsOneWidget);
    final qr =
        tester.widget<PairingQr>(find.byKey(const ValueKey('pairingQr')));
    expect(PairQrPayload.decode(qr.data).code, '482917');

    await unmount(tester);
  });

  testWidgets('Copy code puts the digits on the clipboard', (tester) async {
    final calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      calls.add(call);
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));

    await pumpScreen(tester, pairingApi());
    await tester.tap(find.byKey(const ValueKey('pairingCopy')));
    await tester.pump();

    final copy = calls.where((c) => c.method == 'Clipboard.setData').toList();
    expect(copy, hasLength(1));
    expect((copy.single.arguments as Map)['text'], '482916');
    expect(find.text('Code copied'), findsOneWidget);

    // Let the snackbar's dismiss timer finish before dispose.
    await tester.pump(const Duration(seconds: 5));
    await unmount(tester);
  });

  testWidgets('the device card pair action opens the screen at 320x568',
      (tester) async {
    // The screen is pushed by production code without a test clock, so the
    // default route table (expiresAt = real now + 10 min) is the right fixture.
    final api = FakeApiClient(standardRoutes());
    tester.view.physicalSize = const Size(320, 568);
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

    await tester.tap(find.text('Pair a device'));
    await flushFakeHttp(tester);

    expect(find.byType(PairingQrScreen), findsOneWidget);
    expect(find.byKey(const ValueKey('pairingQr')), findsOneWidget);
    expect(find.text('482916'), findsOneWidget);

    final exceptions = <Object>[];
    while (true) {
      final e = tester.takeException();
      if (e == null) break;
      exceptions.add(e);
    }
    expect(exceptions, isEmpty);

    await unmount(tester);
  });

  // Plan 2.7: the parent approves each new device. The screen reads the claim on its code every 2 s
  // and only the parent's Allow lets the phone have its token.
  group('the claim on the shown code', () {
    FakeApiClient claimApi(Map<String, dynamic> Function() claim,
        {Object? approve = const {'status': 'approved'}}) {
      return pairingApi(extra: {
        'GET /v1/devices/pair/482916/claim': (_) => claim(),
        'POST /v1/devices/pair/claims/c-1/approve': (_) => approve,
        'POST /v1/devices/pair/claims/c-1/deny': (_) => {'status': 'denied'},
      });
    }

    const pending = {
      'status': 'pending',
      'claimId': 'c-1',
      'platform': 'android',
      'model': 'Pixel 8',
      'deviceName': "Sam's phone",
      'osVersion': '15',
    };

    Future<void> nextRead(WidgetTester tester) async {
      await tester.pump(const Duration(seconds: 2));
      await flushFakeHttp(tester);
    }

    testWidgets('no card while no phone has claimed the code', (tester) async {
      final api = claimApi(() => {'status': 'waiting'});
      await pumpScreen(tester, api);
      await nextRead(tester);

      expect(api.calls('GET', '/v1/devices/pair/482916/claim'), isNotEmpty);
      expect(find.byKey(const ValueKey('pairClaimCard')), findsNothing);
      await unmount(tester);
    });

    testWidgets('a pending claim names the phone; Allow approves it', (tester) async {
      final api = claimApi(() => pending);
      await pumpScreen(tester, api);
      await nextRead(tester);

      expect(find.byKey(const ValueKey('pairClaimTitle')), findsOneWidget);
      expect(find.textContaining("Sam's phone"), findsOneWidget);
      expect(api.calls('POST', '/v1/devices/pair/claims/c-1/approve'), isEmpty);

      await tester.tap(find.byKey(const ValueKey('pairClaimAllow')));
      await flushFakeHttp(tester);

      expect(api.calls('POST', '/v1/devices/pair/claims/c-1/approve'), hasLength(1));
      expect(api.calls('POST', '/v1/devices/pair/claims/c-1/deny'), isEmpty);
      expect(find.byKey(const ValueKey('pairClaimAllowed')), findsOneWidget);
      await unmount(tester);
    });

    testWidgets('Deny refuses the claim and stops reading it', (tester) async {
      final api = claimApi(() => pending);
      await pumpScreen(tester, api);
      await nextRead(tester);

      await tester.tap(find.byKey(const ValueKey('pairClaimDeny')));
      await flushFakeHttp(tester);

      expect(api.calls('POST', '/v1/devices/pair/claims/c-1/deny'), hasLength(1));
      expect(api.calls('POST', '/v1/devices/pair/claims/c-1/approve'), isEmpty);
      expect(find.byKey(const ValueKey('pairClaimDenied')), findsOneWidget);
      // The burned code's QR, digits, countdown and copy action are gone (#433 review (a)).
      for (final key in ['pairingQr', 'pairingCode', 'pairingCountdown', 'pairingCopy']) {
        expect(find.byKey(ValueKey(key)), findsNothing, reason: key);
      }
      final reads = api.calls('GET', '/v1/devices/pair/482916/claim').length;
      await nextRead(tester);
      await nextRead(tester);
      expect(api.calls('GET', '/v1/devices/pair/482916/claim'), hasLength(reads));

      // A stranger's claim costs one tap: a new code from the card itself.
      await tester.tap(find.byKey(const ValueKey('pairClaimNewCode')));
      await flushFakeHttp(tester);
      expect(api.calls('POST', '/v1/devices/pair'), hasLength(2));
      expect(find.byKey(const ValueKey('pairClaimCard')), findsNothing);
      expect(find.byKey(const ValueKey('pairingQr')), findsOneWidget);
      await unmount(tester);
    });

    testWidgets('a failed decision says so and keeps Allow and Deny', (tester) async {
      final api = claimApi(() => pending,
          approve: const FakeHttpError(409, {'error': 'claim_not_pending'}));
      await pumpScreen(tester, api);
      await nextRead(tester);

      await tester.tap(find.byKey(const ValueKey('pairClaimAllow')));
      await flushFakeHttp(tester);

      expect(find.byKey(const ValueKey('pairClaimError')), findsOneWidget);
      expect(find.byKey(const ValueKey('pairClaimAllow')), findsOneWidget);
      await unmount(tester);
    });

    testWidgets('once the phone has its token the card says it is paired', (tester) async {
      final api = claimApi(() => {...pending, 'status': 'paired', 'deviceId': 'dev-1'});
      await pumpScreen(tester, api);
      await nextRead(tester);

      expect(find.byKey(const ValueKey('pairClaimPaired')), findsOneWidget);
      expect(find.byKey(const ValueKey('pairClaimAllow')), findsNothing);
      await unmount(tester);
    });

    // Claude's review, point 2 (§7, #429): the Arabic the parent reads is pinned as literals, not looked
    // up through the same ARB key, so a wrong or missing translation turns this red. Karim reviews the
    // wording; if he changes a line, this row changes with the ARB.
    testWidgets('in Arabic the pending and denied cards read as written (RTL)', (tester) async {
      final api = claimApi(() => {...pending, 'deviceName': 'هاتف سام'});
      await tester.pumpWidget(ProviderScope(
        overrides: [apiClientProvider.overrideWithValue(api)],
        child: localizedTestApp(
          PairingQrScreen(childId: 'child-1', clock: () => currentNow),
          locale: const Locale('ar'),
          textDirection: TextDirection.rtl,
        ),
      ));
      await flushFakeHttp(tester);
      await nextRead(tester);

      expect(find.text('جهاز يطلب الانضمام'), findsOneWidget);
      expect(
          find.text('يطلب هاتف سام الإقران. اسمح به فقط إذا كان هو الهاتف الذي أمامك.'),
          findsOneWidget);
      expect(find.text('رفض'), findsOneWidget);
      expect(find.text('سماح'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('pairClaimDeny')));
      await flushFakeHttp(tester);
      expect(find.text('تم الرفض. أنشئ رمزًا جديدًا لإقران هاتف.'), findsOneWidget);
      await unmount(tester);
    });

    test('the phone is named by its device name, or its model without one', () {
      expect(pairClaimDeviceLabel({'deviceName': ' Sam ', 'model': 'Pixel'}), 'Sam');
      expect(pairClaimDeviceLabel({'deviceName': '', 'model': 'Pixel'}), 'Pixel');
      expect(pairClaimDeviceLabel({'model': 'Pixel'}), 'Pixel');
    });
  });
}

/// Lets a fake-Dio request chain complete (Dio dispatches through chained
/// zero-duration timers that only fire when fake time advances).
Future<void> flushFakeHttp(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}
