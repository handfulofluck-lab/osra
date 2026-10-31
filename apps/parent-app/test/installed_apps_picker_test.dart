import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:familyshield_parent/features/rules/rules_editor_screen.dart';
import 'package:familyshield_parent/providers/auth_provider.dart';

import 'fake_api_client.dart';
import 'test_app.dart';

/// Roadmap 3.4: the Rules-editor app picker. Every test exercises the dialog
/// against the network-free fake, including the empty state and Arabic RTL at
/// the smallest supported surface (320×568).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  List<Object> drainExceptions(WidgetTester tester) {
    final exceptions = <Object>[];
    while (true) {
      final e = tester.takeException();
      if (e == null) return exceptions;
      exceptions.add(e);
    }
  }

  /// Dio dispatches through chained zero-duration timers; advance fake time so
  /// the provider's family + apps requests complete.
  Future<void> flushFakeHttp(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> pumpRules(
    WidgetTester tester,
    FakeApiClient api, {
    Locale locale = const Locale('en'),
    TextDirection? textDirection,
    Size? surface,
  }) async {
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
        const RulesEditorScreen(childId: 'child-1'),
        locale: locale,
        textDirection: textDirection,
      ),
    ));
    await tester.pumpAndSettle();
  }

  Future<void> openAppsTab(WidgetTester tester) async {
    // Switch by controller: at 320 px in RTL the third tab sits off-screen, and
    // the test is about the picker, not the tab bar's scroll physics.
    final controller = DefaultTabController.of(tester.element(find.byType(TabBar)));
    controller.animateTo(2);
    await tester.pumpAndSettle();
  }

  Future<void> openPicker(WidgetTester tester) async {
    await openAppsTab(tester);
    final pickerButton = find.byKey(const ValueKey('pickInstalledApp'));
    if (pickerButton.evaluate().isEmpty) {
      // 320×568: the buttons sit below the fold of the lazy Apps list.
      await tester.scrollUntilVisible(
        pickerButton,
        120,
        scrollable: find
            .descendant(
              of: find.byKey(const ValueKey('appsRulesList')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.pumpAndSettle();
    }
    await tester.tap(pickerButton);
    await flushFakeHttp(tester);
    await tester.pumpAndSettle();
  }

  Finder picker() => find.byKey(const ValueKey('installedAppsPicker'));
  Finder tile(String packageId) => find.byKey(ValueKey('installedApp-$packageId'));

  testWidgets('lists reported apps and hides system apps by default', (tester) async {
    final api = FakeApiClient(standardRoutes());
    await pumpRules(tester, api);
    await openPicker(tester);

    expect(picker(), findsOneWidget);
    expect(tile('com.example.video'), findsOneWidget);
    expect(tile('org.example.reader'), findsOneWidget);
    expect(tile('com.android.settings'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('installedAppsSystemFilter')));
    await tester.pumpAndSettle();
    expect(tile('com.android.settings'), findsOneWidget);
    expect(drainExceptions(tester), isEmpty);
  });

  testWidgets('search matches the label and the package id', (tester) async {
    final api = FakeApiClient(standardRoutes());
    await pumpRules(tester, api);
    await openPicker(tester);

    await tester.enterText(find.byKey(const ValueKey('installedAppsSearch')), 'vid');
    await tester.pumpAndSettle();
    expect(tile('com.example.video'), findsOneWidget);
    expect(tile('com.example.game'), findsNothing);
    expect(tile('org.example.reader'), findsNothing);

    await tester.enterText(find.byKey(const ValueKey('installedAppsSearch')), 'org.example');
    await tester.pumpAndSettle();
    expect(tile('org.example.reader'), findsOneWidget);
    expect(tile('com.example.video'), findsNothing);

    await tester.enterText(find.byKey(const ValueKey('installedAppsSearch')), 'no such app');
    await tester.pumpAndSettle();
    expect(find.text('No apps match your search.'), findsOneWidget);
  });

  testWidgets('selecting an app adds an AppRule and the typed path stays available', (tester) async {
    final api = FakeApiClient(standardRoutes());
    await pumpRules(tester, api);
    await openAppsTab(tester);

    // #172 grew the always-allowed block above the rule list, so these sit below the fold on the
    // 800x600 test surface; drag the list rather than shrink the assertions.
    await tester.drag(find.byKey(const ValueKey('appsRulesList')), const Offset(0, -260));
    await tester.pumpAndSettle();
    expect(find.text("Choose from child's apps"), findsOneWidget);
    expect(find.text('Add app rule'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('pickInstalledApp')));
    await flushFakeHttp(tester);
    await tester.pumpAndSettle();
    await tester.tap(tile('com.example.video'));
    await tester.pumpAndSettle();

    expect(picker(), findsNothing);
    expect(find.text('Video'), findsOneWidget); // the new rule card

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    final puts = api.calls('PUT', '/v1/rules/child-1');
    expect(puts, hasLength(1));
    final rules = (puts.single.body['appRules'] as List).cast<Map<String, dynamic>>();
    final video = rules.firstWhere((r) => r['packageId'] == 'com.example.video');
    expect(video['appName'], 'Video');
    expect(video['action'], 'allow');
  });

  testWidgets('an already-ruled app is disabled with a check mark and cannot be added twice', (tester) async {
    final api = FakeApiClient(standardRoutes());
    await pumpRules(tester, api);
    await openPicker(tester);

    final game = tile('com.example.game');
    expect(tester.widget<ListTile>(game).enabled, isFalse);
    expect(find.descendant(of: game, matching: find.byIcon(Icons.check_circle)), findsOneWidget);

    await tester.tap(game);
    await tester.pumpAndSettle();
    expect(picker(), findsOneWidget); // tapping a ruled app does not pop

    await tester.tap(find.byKey(const ValueKey('installedAppsClose')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    final rules = (api.calls('PUT', '/v1/rules/child-1').single.body['appRules'] as List).cast<Map<String, dynamic>>();
    expect(rules.where((r) => r['packageId'] == 'com.example.game'), hasLength(1));
  });

  testWidgets('an empty inventory says so and points at the next check-in', (tester) async {
    final api = FakeApiClient({
      ...standardRoutes(),
      'GET /v1/devices/dev-1/apps': (_) => installedAppsPayload(apps: const []),
    });
    await pumpRules(tester, api);
    await openPicker(tester);

    expect(find.text('No apps reported yet'), findsOneWidget);
    expect(find.textContaining('next check-in'), findsOneWidget);
    expect(find.byKey(const ValueKey('installedAppsList')), findsNothing);
  });

  testWidgets('a failed inventory load shows the error and offers a retry', (tester) async {
    var fail = true;
    final api = FakeApiClient({
      ...standardRoutes(),
      'GET /v1/devices/dev-1/apps': (_) => fail ? const FakeHttpError(500, {'error': 'boom'}) : installedAppsPayload(),
    });
    await pumpRules(tester, api);
    await openPicker(tester);

    expect(find.textContaining('Could not load apps:'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);

    fail = false;
    await tester.tap(find.text('Retry'));
    await flushFakeHttp(tester);
    await tester.pumpAndSettle();
    expect(tile('com.example.video'), findsOneWidget);
  });

  testWidgets('Arabic RTL at 320×568 shows the picker without layout exceptions', (tester) async {
    final api = FakeApiClient(standardRoutes());
    await pumpRules(
      tester,
      api,
      locale: const Locale('ar'),
      textDirection: TextDirection.rtl,
      surface: const Size(320, 568),
    );
    await openPicker(tester);

    expect(find.text('التطبيقات المثبتة'), findsOneWidget);
    expect(find.text('البحث في التطبيقات'), findsOneWidget);
    expect(tile('com.example.video'), findsOneWidget);
    expect(tile('com.android.settings'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('installedAppsSystemFilter')));
    await tester.pumpAndSettle();
    expect(tile('com.android.settings'), findsOneWidget);

    // The dialog's ListTile and the rules screen behind it both stay inside 320 px.
    expect(drainExceptions(tester), isEmpty);
  });

  /// Issue #199 item 5: an app the phone reported as essential is shown as "Always allowed (needed for
  /// calls and safety)" and cannot be selected — a rule on the dialer would silently do nothing. A row
  /// with **no** essential value (an older agent) keeps today's behaviour: selectable, package id shown.
  testWidgets('an essential app cannot be selected, and an unreported one still can', (tester) async {
    // The fixture reports the dialer as essential and says nothing about the browser.
    final payload = installedAppsPayload(apps: [
      {...installedAppJson('com.google.android.dialer', 'Phone'), 'essential': true},
      installedAppJson('com.example.browser', 'Browser'),
    ]);
    final api = FakeApiClient({
      ...standardRoutes(),
      'GET /v1/devices/dev-1/apps': (_) => payload,
    });

    await pumpRules(tester, api);
    await openAppsTab(tester);
    // The always-allowed block above grew (#172), so the picker button is below the fold at 800x600.
    await tester.drag(find.byKey(const ValueKey('appsRulesList')), const Offset(0, -260));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('pickInstalledApp')));
    await flushFakeHttp(tester);
    await tester.pumpAndSettle();

    // The essential row is labelled and disabled.
    expect(find.text('Always allowed (needed for calls and safety)'), findsOneWidget);
    final dialerRow = tester.widget<ListTile>(find.byKey(const ValueKey('installedApp-com.google.android.dialer')));
    expect(dialerRow.enabled, isFalse);
    final browserRow = tester.widget<ListTile>(find.byKey(const ValueKey('installedApp-com.example.browser')));
    expect(browserRow.enabled, isTrue);
    expect(find.text('com.example.browser'), findsOneWidget); // unreported: package id, as today
  });
}
