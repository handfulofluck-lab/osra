import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:familyshield_parent/api/models.dart' show Child, Device, LocationPing;
import 'package:familyshield_parent/features/alerts/alerts_screen.dart';
import 'package:familyshield_parent/features/children/child_detail_screen.dart';
import 'package:familyshield_parent/features/map/family_map_screen.dart';
import 'package:familyshield_parent/features/rules/rules_editor_screen.dart';
import 'package:familyshield_parent/providers/auth_provider.dart';

import 'fake_api_client.dart';
import 'test_app.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  Future<void> pumpScreen(WidgetTester tester, Widget home, FakeApiClient api) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [apiClientProvider.overrideWithValue(api)],
      child: localizedTestApp(home),
    ));
    await tester.pumpAndSettle();
  }

  /// Lets fake-Dio request chains (GET → PUT etc.) complete.
  Future<void> flushFakeHttp(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  /// Runs out a 4s snackbar so no timer is left pending.
  Future<void> runOutSnackbar(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  }

  group('Bonus time (Feature #10)', () {
    FakeApiClient bonusApi() => FakeApiClient({
          ...standardRoutes(),
          'POST /v1/controls/children/child-1/bonus': (_) => {'ok': true},
        });

    testWidgets('+15/+30/+60 POST {minutes} and confirm via snackbar', (tester) async {
      final api = bonusApi();
      await pumpScreen(tester, const ChildDetailScreen(childId: 'child-1'), api);

      expect(find.text('Bonus time'), findsOneWidget);
      final scrollable = find.byType(Scrollable).first;
      for (final (label, minutes) in [('+15', 15), ('+30', 30), ('+60', 60)]) {
        await tester.scrollUntilVisible(find.text(label), 100, scrollable: scrollable);
        await tester.pumpAndSettle();
        await tester.tap(find.text(label));
        await flushFakeHttp(tester);
        await tester.pumpAndSettle();

        final posts = api.calls('POST', '/v1/controls/children/child-1/bonus');
        expect(posts.last.body['minutes'], minutes);
        expect(find.text('+$minutes extra minutes granted today'), findsOneWidget);
        await runOutSnackbar(tester);
      }
      expect(api.calls('POST', '/v1/controls/children/child-1/bonus'), hasLength(3));
    });
  });

  group('Always-allowed apps (Feature #9)', () {
    FakeApiClient rulesApi() => FakeApiClient({
          ...standardRoutes(),
          'GET /v1/rules/child-1': (_) => ruleSetPayload('child-1', alwaysAllowedApps: ['com.edu.app']),
        });

    Future<void> openAppsTab(WidgetTester tester, FakeApiClient api) async {
      await pumpScreen(tester, const RulesEditorScreen(childId: 'child-1'), api);
      await tester.tap(find.text('Apps'));
      await tester.pumpAndSettle();
    }

    testWidgets('helper text and chips render from the loaded ruleset', (tester) async {
      final api = rulesApi();
      await openAppsTab(tester, api);

      expect(find.text('Always allowed'), findsOneWidget);
      expect(find.text('These apps stay open during bedtime, school time, pause and routines.'), findsOneWidget);
      expect(find.text('com.edu.app'), findsOneWidget);
    });

    testWidgets('add then remove an app; Save PUTs alwaysAllowedApps', (tester) async {
      final api = rulesApi();
      await openAppsTab(tester, api);

      // Add com.new.app via the dialog.
      await tester.tap(find.text('Add app'));
      await tester.pumpAndSettle();
      final dialog = find.byType(AlertDialog);
      await tester.enterText(find.descendant(of: dialog, matching: find.byType(TextField)), 'com.new.app');
      await tester.tap(find.descendant(of: dialog, matching: find.text('Add')));
      await tester.pumpAndSettle();
      expect(find.text('com.new.app'), findsOneWidget);

      // Save → PUT carries both apps.
      await tester.tap(find.text('Save'));
      await flushFakeHttp(tester);
      await tester.pumpAndSettle();
      var puts = api.calls('PUT', '/v1/rules/child-1');
      expect(puts, hasLength(1));
      expect(puts.single.body['alwaysAllowedApps'], ['com.edu.app', 'com.new.app']);
      await runOutSnackbar(tester);

      // Remove the chip, save again → PUT carries only the remaining app.
      final chip = find.widgetWithText(InputChip, 'com.new.app');
      await tester.tap(find.descendant(of: chip, matching: find.byIcon(Icons.clear)));
      await tester.pumpAndSettle();
      expect(find.text('com.new.app'), findsNothing);

      await tester.tap(find.text('Save'));
      await flushFakeHttp(tester);
      await tester.pumpAndSettle();
      puts = api.calls('PUT', '/v1/rules/child-1');
      expect(puts, hasLength(2));
      expect(puts.last.body['alwaysAllowedApps'], ['com.edu.app']);
      await runOutSnackbar(tester);
    });
  });

  group('Install request approval (Feature #8)', () {
    Map<String, dynamic> installAlert() => {
          ...alertJson('i1', 'info', 'install_request', 'App install requested', DateTime.now()),
          'metadata': {'packageId': 'com.vile.app', 'appName': 'Vile App'},
        };

    testWidgets('detail shows Block; Block appends a block appRule and PUTs it', (tester) async {
      final api = FakeApiClient(standardRoutes(alerts: [installAlert()]));
      await pumpScreen(tester, const AlertsScreen(), api);

      await tester.tap(find.text('App install requested'));
      await tester.pumpAndSettle();

      expect(find.widgetWithText(FilledButton, 'Block this app'), findsOneWidget);
      await tester.tap(find.text('Block this app'));
      await flushFakeHttp(tester);
      await tester.pumpAndSettle();

      final puts = api.calls('PUT', '/v1/rules/child-1');
      expect(puts, hasLength(1));
      final appRules = puts.single.body['appRules'] as List;
      expect(appRules, hasLength(2)); // fixture rule + the appended block
      expect(appRules.last, {
        'packageId': 'com.vile.app',
        'appName': 'Vile App',
        'action': 'block',
      });
      expect(find.text('App blocked'), findsOneWidget);
      await runOutSnackbar(tester);
    });

    testWidgets('Allow just dismisses the dialog with a snackbar', (tester) async {
      final api = FakeApiClient(standardRoutes(alerts: [installAlert()]));
      await pumpScreen(tester, const AlertsScreen(), api);

      await tester.tap(find.text('App install requested'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Allow'));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);
      expect(api.calls('PUT', '/v1/rules/child-1'), isEmpty);
      expect(find.text('Allowed'), findsOneWidget);
      await runOutSnackbar(tester);
    });
  });

  group('Location history scrubber (Feature #15)', () {
    FakeApiClient historyApi() {
      final now = DateTime.now();
      DateTime at(int h, int m) => DateTime(now.year, now.month, now.day, h, m);
      return FakeApiClient({
        ...standardRoutes(),
        // Deliberately unsorted (newest first) — the provider must sort ascending.
        'GET /v1/location/child-1/history': (_) => {
              'pings': [
                {'lat': 30.03, 'lng': 31.03, 'ts': at(8, 40).toIso8601String(), 'accuracyM': 20},
                {'lat': 30.01, 'lng': 31.01, 'ts': at(8, 20).toIso8601String(), 'accuracyM': 15},
                {'lat': 30.0, 'lng': 31.0, 'ts': at(8, 0).toIso8601String(), 'accuracyM': 12},
              ],
            },
      });
    }

    Future<void> openLocationTab(WidgetTester tester, FakeApiClient api) async {
      await pumpScreen(tester, const ChildDetailScreen(childId: 'child-1'), api);
      await tester.tap(find.text('Location'));
      await tester.pumpAndSettle();
    }

    testWidgets('renders the readout and slider movement changes the time text', (tester) async {
      final api = historyApi();
      await openLocationTab(tester, api);

      expect(api.calls('GET', '/v1/location/child-1/history'), hasLength(1));
      expect(find.text("Today's route"), findsOneWidget);
      // Sorted ascending → starts at the earliest ping.
      expect(find.textContaining('08:00'), findsOneWidget);
      expect(find.textContaining('±12 m'), findsOneWidget);

      // ▶ steps 15 min of timeline: 08:00 → nearest to 08:15 is 08:20.
      await tester.tap(find.byTooltip('Forward 15 min'));
      await tester.pumpAndSettle();
      expect(find.textContaining('08:20'), findsOneWidget);

      // Drag the slider fully right → last ping (08:40).
      await tester.drag(find.byType(Slider), const Offset(800, 0));
      await tester.pumpAndSettle();
      expect(find.textContaining('08:40'), findsOneWidget);
      expect(find.textContaining('±20 m'), findsOneWidget);

      // ◀ steps back: 08:40 → nearest to 08:25 is 08:20.
      await tester.tap(find.byTooltip('Back 15 min'));
      await tester.pumpAndSettle();
      expect(find.textContaining('08:20'), findsOneWidget);
    });

    testWidgets('empty history shows the empty state', (tester) async {
      final api = FakeApiClient({
        ...standardRoutes(),
        'GET /v1/location/child-1/history': (_) => {'pings': <dynamic>[]},
      });
      await openLocationTab(tester, api);

      expect(find.text('No location history for today'), findsOneWidget);
      expect(find.byType(Slider), findsNothing);
    });
  });

  group('Map sheet battery line (Feature #15)', () {
    const child = Child(id: 'child-1', familyId: 'fam-1', displayName: 'Alex', birthYear: 2013);
    final ping = LocationPing(deviceId: 'dev-1', lat: 30.0, lng: 31.0, accuracyM: 10, timestamp: DateTime(2026, 9, 16, 12));

    Future<void> pumpSheet(WidgetTester tester, Device? device) async {
      final api = FakeApiClient(standardRoutes());
      await tester.pumpWidget(ProviderScope(
        overrides: [apiClientProvider.overrideWithValue(api)],
        child: localizedTestApp(Scaffold(body: ChildMapSheet(child: child, ping: ping, device: device))),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('renders Battery: NN% when the device reports a level', (tester) async {
      await pumpSheet(tester, const Device(
        id: 'dev-1',
        childId: 'child-1',
        platform: 'android',
        model: 'Pixel 7a',
        osVersion: '14',
        status: 'online',
        batteryPct: 55,
      ));
      expect(find.text('Battery: 55%'), findsOneWidget);
    });

    testWidgets('battery line hidden at 0% or without a device', (tester) async {
      await pumpSheet(tester, const Device(
        id: 'dev-2',
        childId: 'child-1',
        platform: 'android',
        model: 'Galaxy A14',
        osVersion: '13',
        status: 'online',
        batteryPct: 0,
      ));
      expect(find.text('Battery: 0%'), findsNothing);

      await pumpSheet(tester, null);
      expect(find.textContaining('Battery'), findsNothing);
    });
  });
}
