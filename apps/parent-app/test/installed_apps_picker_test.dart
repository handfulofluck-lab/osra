import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:familyshield_parent/features/rules/app_picker.dart';
import 'package:familyshield_parent/features/rules/rules_editor_screen.dart';
import 'package:familyshield_parent/l10n/app_localizations_ar.dart';
import 'package:familyshield_parent/providers/auth_provider.dart';

import 'fake_api_client.dart';
import 'test_app.dart';

/// U33 (#868): the Rules-editor app picker — one full-screen multi-select list of the child's own
/// reported apps. Every test runs against the network-free fake, including the empty state, the
/// per-device grouping and Arabic RTL at the smallest supported surface (320×568).
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

  Finder picker() => find.byKey(const ValueKey('appPicker'));
  Finder tile(String packageId) => find.byKey(ValueKey('appPickerRow-$packageId'));
  Finder checkbox(String packageId) => find.byKey(ValueKey('appPickerCheck-$packageId'));

  testWidgets('lists reported apps and hides system apps by default', (tester) async {
    final api = FakeApiClient(standardRoutes());
    await pumpRules(tester, api);
    await openPicker(tester);

    expect(picker(), findsOneWidget);
    expect(tile('com.example.video'), findsOneWidget);
    expect(tile('org.example.reader'), findsOneWidget);
    expect(tile('com.android.settings'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('appPickerSystemFilter')));
    await tester.pumpAndSettle();
    expect(tile('com.android.settings'), findsOneWidget);
    expect(drainExceptions(tester), isEmpty);
  });

  testWidgets('search matches the app name only, never the package id', (tester) async {
    final api = FakeApiClient(standardRoutes());
    await pumpRules(tester, api);
    await openPicker(tester);

    await tester.enterText(find.byKey(const ValueKey('appPickerSearch')), 'vid');
    await tester.pumpAndSettle();
    expect(tile('com.example.video'), findsOneWidget);
    expect(tile('com.example.game'), findsNothing);
    expect(tile('org.example.reader'), findsNothing);

    // U33: the search is the parent's vocabulary. A package id — 'org.example' — is not an app name
    // and no longer matches; that is the deliberate change from the #830-era picker, which matched it.
    await tester.enterText(find.byKey(const ValueKey('appPickerSearch')), 'org.example');
    await tester.pumpAndSettle();
    expect(tile('org.example.reader'), findsNothing);
    expect(find.text('No apps match your search.'), findsOneWidget);
    expect(find.byKey(const ValueKey('appPickerNoMatch')), findsOneWidget);
  });

  testWidgets('choosing two apps adds two rules and shows no package id', (tester) async {
    final api = FakeApiClient(standardRoutes());
    await pumpRules(tester, api);
    await openPicker(tester);

    await tester.tap(tile('com.example.video'));
    await tester.pumpAndSettle();
    await tester.tap(tile('org.example.reader'));
    await tester.pumpAndSettle();
    expect(tester.widget<Checkbox>(checkbox('com.example.video')).value, isTrue);
    expect(tester.widget<Checkbox>(checkbox('org.example.reader')).value, isTrue);

    await tester.tap(find.byKey(const ValueKey('appPickerConfirm')));
    await tester.pumpAndSettle();
    expect(picker(), findsNothing);
    // The two new rows exist; the PUT below is what proves their contents — the rule list is lazy, so
    // a card below the fold is not in the element tree to be found by text.
    expect(find.text('Video'), findsOneWidget);
    // U33: the typed path is gone — no "Add app rule" button and no package id on any row.
    expect(find.text('Add app rule'), findsNothing);
    expect(find.text('com.example.video'), findsNothing);
    expect(find.text('org.example.reader'), findsNothing);

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    final puts = api.calls('PUT', '/v1/rules/child-1');
    expect(puts, hasLength(1));
    final rules = (puts.single.body['appRules'] as List).cast<Map<String, dynamic>>();
    expect(rules.map((r) => r['packageId']), containsAll(<String>['com.example.video', 'org.example.reader']));
    expect(rules.firstWhere((r) => r['packageId'] == 'com.example.video')['appName'], 'Video');
    expect(rules.firstWhere((r) => r['packageId'] == 'org.example.reader')['action'], 'allow');
  });

  testWidgets('the confirm button is disabled until something is chosen', (tester) async {
    final api = FakeApiClient(standardRoutes());
    await pumpRules(tester, api);
    await openPicker(tester);

    expect(tester.widget<FilledButton>(find.byKey(const ValueKey('appPickerConfirm'))).onPressed, isNull);
    await tester.tap(tile('com.example.video'));
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(find.byKey(const ValueKey('appPickerConfirm'))).onPressed, isNotNull);
  });

  testWidgets('an already-ruled app is disabled and cannot be added twice', (tester) async {
    final api = FakeApiClient(standardRoutes());
    await pumpRules(tester, api);
    await openPicker(tester);

    final game = tile('com.example.game');
    expect(tester.widget<ListTile>(game).enabled, isFalse);
    expect(tester.widget<Checkbox>(checkbox('com.example.game')).onChanged, isNull);
    // The rule state is the subtitle the parent reads: a 60-minute daily limit in this fixture.
    expect(find.text('Daily limit: 60 min'), findsOneWidget);

    await tester.tap(game);
    await tester.pumpAndSettle();
    expect(picker(), findsOneWidget); // tapping a ruled app does not close the picker

    await tester.tap(find.byType(CloseButton));
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
    expect(find.byKey(const ValueKey('appPickerEmpty')), findsOneWidget);
    expect(find.byKey(const ValueKey('appPickerList')), findsNothing);
    // No text-field fallback anywhere in the empty state.
    expect(find.byType(TextField), findsOneWidget); // the search field, and only it
  });

  testWidgets('a failed inventory load shows the error and offers a retry', (tester) async {
    var fail = true;
    final api = FakeApiClient({
      ...standardRoutes(),
      'GET /v1/devices/dev-1/apps': (_) => fail ? const FakeHttpError(500, {'error': 'boom'}) : installedAppsPayload(),
    });
    await pumpRules(tester, api);
    await openPicker(tester);

    // #872 condition 1: a whole sentence with no placeholder, so nothing can be spliced into it.
    expect(find.text("Couldn't load apps. Check your connection and try again."), findsOneWidget);
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

    await tester.tap(find.byKey(const ValueKey('appPickerSystemFilter')));
    await tester.pumpAndSettle();
    expect(tile('com.android.settings'), findsOneWidget);

    // The full-screen list and the confirm bar both stay inside 320 px.
    expect(drainExceptions(tester), isEmpty);
  });

  /// Issue #199 item 5: an app the phone reported as essential is shown as "Always allowed (needed for
  /// calls and safety)" and cannot be selected — a rule on the dialer would silently do nothing.
  testWidgets('an essential app cannot be selected, and an ordinary one can', (tester) async {
    final payload = installedAppsPayload(apps: [
      {...installedAppJson('com.google.android.dialer', 'Phone'), 'essential': true},
      installedAppJson('com.example.browser', 'Browser'),
    ]);
    final api = FakeApiClient({
      ...standardRoutes(),
      'GET /v1/devices/dev-1/apps': (_) => payload,
    });

    await pumpRules(tester, api);
    await openPicker(tester);

    expect(find.text('Always allowed (needed for calls and safety)'), findsOneWidget);
    final dialerRow = tester.widget<ListTile>(tile('com.google.android.dialer'));
    expect(dialerRow.enabled, isFalse);
    final browserRow = tester.widget<ListTile>(tile('com.example.browser'));
    expect(browserRow.enabled, isTrue);
    // U33: an app with no rule and no essential flag shows its name and nothing technical — the
    // #830-era picker printed the package id under every row.
    expect(find.text('com.example.browser'), findsNothing);
  });

  /// U33: the icon arrives from the server as a URL. Until it does the row draws a letter avatar in the
  /// brand tint; an empty string is not a URL and must not be requested.
  testWidgets('a missing icon draws a letter avatar and an icon URL draws an image', (tester) async {
    final payload = installedAppsPayload(apps: [
      installedAppJson('com.example.video', 'Video'),
      {...installedAppJson('com.example.music', 'Music'), 'iconUrl': 'https://cdn.example/apps/music.webp'},
      {...installedAppJson('com.example.blank', 'Blank'), 'iconUrl': ''},
    ]);
    final api = FakeApiClient({
      ...standardRoutes(),
      'GET /v1/devices/dev-1/apps': (_) => payload,
    });
    await pumpRules(tester, api);
    await openPicker(tester);

    final videoRow = find.byKey(const ValueKey('appPickerRow-com.example.video'));
    expect(find.descendant(of: videoRow, matching: find.text('V')), findsOneWidget);
    expect(find.descendant(of: videoRow, matching: find.byType(Image)), findsNothing);

    final musicRow = find.byKey(const ValueKey('appPickerRow-com.example.music'));
    expect(find.descendant(of: musicRow, matching: find.byType(Image)), findsOneWidget);

    // An empty iconUrl is "no icon yet", not a request for the current page.
    final blankRow = find.byKey(const ValueKey('appPickerRow-com.example.blank'));
    expect(find.descendant(of: blankRow, matching: find.byType(Image)), findsNothing);
    expect(find.descendant(of: blankRow, matching: find.text('B')), findsOneWidget);
  });

  /// U33: with more than one reporting device the rows are grouped under the device, the same app
  /// appears once in each group, and ticking it in one group ticks it in the other.
  testWidgets('two devices group their apps and share the tick', (tester) async {
    final api = FakeApiClient({
      ...standardRoutes(familyMe: familyMeMixedDevices()),
      'GET /v1/devices/dev-1/apps': (_) => installedAppsPayload(),
      'GET /v1/devices/dev-3/apps': (_) => installedAppsPayload(apps: [
            installedAppJson('com.example.video', 'Video'),
            installedAppJson('com.example.maps', 'Maps'),
          ]),
    });
    await pumpRules(tester, api);
    await openPicker(tester);

    expect(find.byKey(const ValueKey('appPickerGroup-dev-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('appPickerGroup-dev-3')), findsOneWidget);
    expect(find.text('iPhone 13'), findsOneWidget);
    expect(find.text('Galaxy Tab'), findsOneWidget);

    // Video is reported by both devices: two rows, one tick.
    expect(find.byKey(const ValueKey('appPickerRow-com.example.video')), findsNWidgets(2));
    await tester.tap(find.byKey(const ValueKey('appPickerRow-com.example.video')).first);
    await tester.pumpAndSettle();
    for (final box in tester.widgetList<Checkbox>(checkbox('com.example.video'))) {
      expect(box.value, isTrue);
    }
    expect(drainExceptions(tester), isEmpty);
  });

  /// Codex's #872 finding ("pending versus confirmed absence"): before any device sends its app list, a
  /// missing name means we do not know yet — not that the app was removed. The two lines are different on
  /// purpose, and saying the wrong one claims something the parent will act on.
  testWidgets('no report yet says the name is pending, and never that the app is gone', (tester) async {
    final api = FakeApiClient({
      ...standardRoutes(),
      'GET /v1/rules/child-1': (_) => ruleSetPayload('child-1', alwaysAllowedApps: const ['com.example.gone']),
      // A report that exists but carries no `reportedAt`: no device has checked in with its list.
      'GET /v1/devices/dev-1/apps': (_) => installedAppsPayload(apps: const [], reportedAt: null),
    });
    await pumpRules(tester, api);
    await openAppsTab(tester);

    // Mutant: one fallback line for both states, and this row reads «App no longer installed» before any
    // device has reported — a statement about the child's phone that nothing has supported.
    expect(find.text('Name not available yet'), findsWidgets);
    expect(find.text('App no longer installed'), findsNothing);
    expect(find.textContaining('com.example.gone'), findsNothing);
  });

  /// #872 conditions 3, 4 and 5 (UI/UX Bureau): each has its own row so the next reader can see what a
  /// regression looks like.
  testWidgets('a device that reports nothing keeps its header and says so', (tester) async {
    // Mutant: `if (visible.isEmpty) continue;` — the whole group is skipped and the second phone vanishes.
    final api = FakeApiClient({
      ...standardRoutes(familyMe: familyMeMixedDevices()),
      'GET /v1/devices/dev-1/apps': (_) => installedAppsPayload(),
      'GET /v1/devices/dev-3/apps': (_) => installedAppsPayload(apps: const []),
    });
    await pumpRules(tester, api);
    await openPicker(tester);

    expect(find.byKey(const ValueKey('appPickerGroup-dev-3')), findsOneWidget);
    expect(find.text('Galaxy Tab'), findsOneWidget);
    expect(find.byKey(const ValueKey('appPickerGroupEmpty-dev-3')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('appPickerGroupEmpty-dev-3')),
        matching: find.text('No apps reported yet'),
      ),
      findsOneWidget,
    );
  });

  testWidgets("a truncated inventory says so above that device's apps", (tester) async {
    // Mutant: drop the notice and a cut list reads as "this app is not installed", which is a different
    // and wrong statement.
    final api = FakeApiClient({
      ...standardRoutes(),
      'GET /v1/devices/dev-1/apps': (_) => installedAppsPayload(
            apps: [
              installedAppJson('com.example.video', 'Video'),
              installedAppJson('com.example.maps', 'Maps'),
            ],
            truncated: true,
          ),
    });
    await pumpRules(tester, api);
    await openPicker(tester);

    final notice = find.byKey(const ValueKey('appPickerTruncated-dev-1'));
    expect(notice, findsOneWidget);
    expect(
      find.descendant(of: notice, matching: find.text('Showing the first 2 apps.')),
      findsOneWidget,
    );
  });

  testWidgets('the confirm button says Save, not "Add app"', (tester) async {
    // Mutant: put `l10n.addApp` back — the label says one app after several are ticked.
    final api = FakeApiClient({
      ...standardRoutes(),
      'GET /v1/devices/dev-1/apps': (_) => installedAppsPayload(),
    });
    await pumpRules(tester, api);
    await openPicker(tester);

    final confirm = find.byKey(const ValueKey('appPickerConfirm'));
    expect(find.descendant(of: confirm, matching: find.text('Save')), findsOneWidget);
    expect(find.text('Add app'), findsNothing);
  });

  /// A parent's own chips and rows show the app's name and icon, not the id. A stored id whose app the
  /// phone no longer reports is the one place the id still appears — it is the saved value, not a prompt.
  testWidgets('the always-allowed chips show names, and an app nothing reports says so', (tester) async {
    final api = FakeApiClient({
      ...standardRoutes(),
      'GET /v1/rules/child-1': (_) => ruleSetPayload('child-1', alwaysAllowedApps: const [
            'com.example.video',
            'com.example.gone',
          ]),
    });
    await pumpRules(tester, api);
    await openAppsTab(tester);

    expect(find.text('Video'), findsWidgets);
    // #872 condition 2 (Claude's data shape, 05:16Z): the name comes from the installed-apps report and
    // the fallback is the Bureaus' line. Mutant: `apps[id]?.label ?? id` and the id is back on screen.
    expect(find.text('App no longer installed'), findsWidgets);
    expect(find.textContaining('com.example.gone'), findsNothing);
    expect(drainExceptions(tester), isEmpty);
  });

  /// Karim's approved Q9 (2026-10-31 09:13Z), pinned as a literal the way #486 pins its lines. A
  /// generator run, a merge or a well-meaning edit that changes the wording fails here instead of
  /// shipping text he did not approve.
  test('the approved Arabic for the essential row is pinned verbatim', () {
    expect(AppLocalizationsAr().essentialAppRow, 'مسموح دائمًا (ضروري للمكالمات والسلامة)');
  });

  /// The picker is reachable from the always-allowed list too, and it is the same widget there.
  testWidgets('the always-allowed Add app button opens the same picker', (tester) async {
    final api = FakeApiClient(standardRoutes());
    await pumpRules(tester, api);
    await openAppsTab(tester);

    final addApp = find.widgetWithText(OutlinedButton, 'Add app');
    await tester.ensureVisible(addApp);
    await tester.pumpAndSettle();
    await tester.tap(addApp);
    await flushFakeHttp(tester);
    await tester.pumpAndSettle();
    expect(picker(), findsOneWidget);
    expect(find.byType(AppPicker), findsOneWidget);
  });
}
