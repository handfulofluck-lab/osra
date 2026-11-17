import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:familyshield_parent/features/children/child_detail_screen.dart';
import 'package:familyshield_parent/features/pairing/add_computer_screen.dart';
import 'package:familyshield_parent/features/pairing/computer_target.dart';
import 'package:familyshield_parent/features/pairing/pair_qr_payload.dart';
import 'package:familyshield_parent/features/pairing/pair_qr_screen.dart';
import 'package:familyshield_parent/providers/auth_provider.dart';

import 'fake_api_client.dart';
import 'test_app.dart';

/// ADR-0041 D5 — "Add a computer" on the child page (#627).
///
/// The flow is the existing phone pairing, not a second one: the same `POST /v1/devices/pair`, the same
/// six-digit code, the same claim and Allow / Deny. What the platform choice changes is the copy, the
/// download address and the share action, and the QR gives way to that address because a computer has no
/// camera. The rows here pin those differences, not the pairing machinery `pairing_qr_test.dart` covers.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  var currentNow = DateTime.utc(2026, 1, 1, 12, 0, 0);

  setUp(() => currentNow = DateTime.utc(2026, 1, 1, 12, 0, 0));

  FakeApiClient computerApi() {
    final routes = standardRoutes();
    routes['POST /v1/devices/pair'] = (_) => {
          'code': '482916',
          'expiresAt': currentNow.add(kPairCodeTtl).toUtc().toIso8601String(),
        };
    return FakeApiClient(routes);
  }

  Future<void> pump(WidgetTester tester, FakeApiClient api, Widget home,
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
      child: localizedTestApp(home),
    ));
    await flushFakeHttp(tester);
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  }

  /// The address as the screen renders it. `SelectableText` builds a `Text` and an `EditableText`, so
  /// `find.text` counts it twice; the key names the one widget to read.
  String? shownAddress(WidgetTester tester) => tester
      .widget<SelectableText>(find.byKey(const ValueKey('computerAddress')))
      .data;

  testWidgets('(a) the child page offers Add a computer, which opens the platform choice',
      (tester) async {
    final api = computerApi();
    await pump(tester, api, const ChildDetailScreen(childId: 'child-1'));

    final entry = find.byKey(const ValueKey('addComputerButton'));
    expect(entry, findsOneWidget);

    await tester.tap(entry);
    await tester.pumpAndSettle();

    expect(find.byType(AddComputerScreen), findsOneWidget);
    expect(find.byKey(const ValueKey('addComputer-windows')), findsOneWidget);
    expect(find.byKey(const ValueKey('addComputer-macos')), findsOneWidget);
    expect(find.text('Windows'), findsOneWidget);
    expect(find.text('Mac'), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('(b) choosing Windows shows the existing pairing code and osratech.com/windows',
      (tester) async {
    final api = computerApi();
    await pump(tester, api, AddComputerScreen(childId: 'child-1', clock: () => currentNow));

    await tester.tap(find.byKey(const ValueKey('addComputer-windows')));
    await flushFakeHttp(tester);

    expect(find.byType(PairingQrScreen), findsOneWidget);
    expect(api.calls('POST', '/v1/devices/pair'), hasLength(1));
    expect(api.calls('POST', '/v1/devices/pair').single.body['childId'], 'child-1');
    expect(find.text('482916'), findsOneWidget);
    expect(shownAddress(tester), 'osratech.com/windows');
    // A computer has no camera: the QR is a phone-only affordance.
    expect(find.byKey(const ValueKey('pairingQr')), findsNothing);

    await unmount(tester);
  });

  testWidgets('(c) choosing Mac shows osratech.com/mac', (tester) async {
    final api = computerApi();
    await pump(tester, api, AddComputerScreen(childId: 'child-1', clock: () => currentNow));

    await tester.tap(find.byKey(const ValueKey('addComputer-macos')));
    await flushFakeHttp(tester);

    expect(find.text('482916'), findsOneWidget);
    expect(shownAddress(tester), 'osratech.com/mac');

    await unmount(tester);
  });

  testWidgets('(d) Copy link and Send the link both put the address on the clipboard',
      (tester) async {
    final calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      calls.add(call);
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));

    final api = computerApi();
    await pump(tester, api,
        PairingQrScreen(childId: 'child-1', clock: () => currentNow, computer: ComputerTarget.windows));

    List<String> copied() => [
          for (final c in calls)
            if (c.method == 'Clipboard.setData') (c.arguments as Map)['text'] as String,
        ];

    await tester.tap(find.byKey(const ValueKey('computerCopyLink')));
    await tester.pump();
    expect(copied(), ['osratech.com/windows']);
    expect(find.text('Link copied'), findsOneWidget);
    // A snackbar queues behind the one on screen, so wait for the first to leave before the next action.
    for (var i = 0; i < 10 && tester.any(find.byType(SnackBar)); i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    expect(find.byType(SnackBar), findsNothing);

    // No share plugin ships in this app (ADR-0041 D5.1 allows the clipboard plus the line that says so),
    // so "Send the link" must still hand over the address itself.
    await tester.tap(find.byKey(const ValueKey('computerSendLink')));
    await tester.pump();
    expect(copied(), ['osratech.com/windows', 'osratech.com/windows']);
    expect(
        find.text('Link copied. Paste it into a message to send it to yourself or the computer.'),
        findsOneWidget);
    expect(find.text('Send the link to yourself, or type it into the computer\'s browser.'),
        findsOneWidget);
    await tester.pump(const Duration(seconds: 5));

    await unmount(tester);
  });

  testWidgets('(f) the platform choice and the code layout at 320x568 without an exception',
      (tester) async {
    final api = computerApi();
    await pump(tester, api, AddComputerScreen(childId: 'child-1', clock: () => currentNow),
        surface: const Size(320, 568));
    expect(find.byKey(const ValueKey('addComputer-windows')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('addComputer-windows')));
    await flushFakeHttp(tester);
    await tester.pumpAndSettle();

    expect(find.text('482916'), findsOneWidget);
    expect(find.text('osratech.com/windows'), findsOneWidget);

    final exceptions = <Object>[];
    while (true) {
      final e = tester.takeException();
      if (e == null) break;
      exceptions.add(e);
    }
    expect(exceptions, isEmpty);

    await unmount(tester);
  });
}

/// Lets a fake-Dio request chain complete (Dio dispatches through chained zero-duration timers that only
/// fire when fake time advances).
Future<void> flushFakeHttp(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}
