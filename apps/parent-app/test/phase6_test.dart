import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:familyshield_parent/api/models.dart' show Child;
import 'package:familyshield_parent/app.dart' show FamilyShieldApp;
import 'package:familyshield_parent/features/children/child_detail_screen.dart';
import 'package:familyshield_parent/features/family/family_screen.dart';
import 'package:familyshield_parent/features/map/family_map_screen.dart';
import 'package:familyshield_parent/features/dashboard/dashboard_screen.dart';
import 'package:familyshield_parent/features/social/social_screen.dart';
import 'package:familyshield_parent/providers/auth_provider.dart';

import 'fake_api_client.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  Future<void> pumpScreen(WidgetTester tester, Widget home, FakeApiClient api) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [apiClientProvider.overrideWithValue(api)],
      child: MaterialApp(home: home),
    ));
    await tester.pumpAndSettle();
  }

  /// Lets fake-Dio request chains complete.
  Future<void> flushFakeHttp(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Finder fieldByLabel(String label) => find.ancestor(of: find.text(label), matching: find.byType(TextField));

  group('FamilyScreen invites (Feature #13)', () {
    Map<String, dynamic> familyWithParents() => {
          ...familyMeTwoChildren(),
          'parents': [
            {
              'id': 'par-1',
              'familyId': 'fam-1',
              'email': 'qa@familyshield.dev',
              'displayName': 'QA Parent',
              'role': 'owner',
            },
            {
              'id': 'par-2',
              'familyId': 'fam-1',
              'email': 'co@familyshield.dev',
              'displayName': 'Co Parent',
              'role': 'co-parent',
            },
          ],
        };

    /// Stateful invite store mirroring the server: POST adds, DELETE clears.
    FakeApiClient invitesApi(List<Map<String, dynamic>> invites) => FakeApiClient({
          ...standardRoutes(),
          'GET /v1/family/me': (_) => familyWithParents(),
          'GET /v1/family/invites': (_) => {'items': invites},
          'POST /v1/family/invites': (req) {
            invites.add({
              'id': 'inv-1',
              'email': req.body['email'],
              'role': req.body['role'],
              'permissions': req.body['permissions'],
              'status': 'pending',
            });
            return {'invite': invites.last, 'acceptToken': 'tok-abc-123'};
          },
          'DELETE /v1/family/invites/inv-1': (_) {
            invites.clear();
            return {'ok': true};
          },
        });

    testWidgets('invite dialog POSTs email/role/permissions and shows the accept token', (tester) async {
      final invites = <Map<String, dynamic>>[];
      final api = invitesApi(invites);
      await pumpScreen(tester, const FamilyScreen(), api);

      // Parents listed with role chips.
      expect(find.text('QA Parent'), findsOneWidget);
      expect(find.text('Co Parent'), findsOneWidget);
      expect(find.text('owner'), findsOneWidget);
      expect(find.text('co-parent'), findsOneWidget);
      expect(find.text('No pending invites'), findsOneWidget);

      // Open the invite dialog.
      await tester.tap(find.text('Invite member'));
      await tester.pumpAndSettle();
      await tester.enterText(fieldByLabel('Email'), 'guardian@familyshield.dev');

      // Switch the role dropdown from co-parent to guardian.
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Guardian').last);
      await tester.pumpAndSettle();

      // Uncheck the Social permission; rules/location/alerts stay on.
      await tester.tap(find.widgetWithText(CheckboxListTile, 'Social'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Send invite'));
      await flushFakeHttp(tester);
      await tester.pumpAndSettle();

      final posts = api.calls('POST', '/v1/family/invites');
      expect(posts, hasLength(1));
      expect(posts.single.body['email'], 'guardian@familyshield.dev');
      expect(posts.single.body['role'], 'guardian');
      expect(posts.single.body['permissions'], ['rules', 'location', 'alerts']);

      // The accept token + test-build share hint are shown.
      expect(find.text('tok-abc-123'), findsOneWidget);
      expect(
        find.text('(test build: share this token — the invited parent registers, then POSTs accept with it)'),
        findsOneWidget,
      );

      // Done closes the dialog; the pending list refreshes via invalidate.
      await tester.tap(find.text('Done'));
      await flushFakeHttp(tester);
      await tester.pumpAndSettle();
      expect(find.text('guardian@familyshield.dev'), findsOneWidget);
      expect(find.text('No pending invites'), findsNothing);

      // Revoke issues the owner DELETE and empties the list.
      await tester.tap(find.byTooltip('Revoke invite'));
      await flushFakeHttp(tester);
      await tester.pumpAndSettle();
      expect(api.calls('DELETE', '/v1/family/invites/inv-1'), hasLength(1));
      expect(find.text('guardian@familyshield.dev'), findsNothing);
      expect(find.text('No pending invites'), findsOneWidget);
    });
  });

  group('Dashboard overflow menu', () {
    testWidgets("'Family members' navigates to the family screen", (tester) async {
      final api = FakeApiClient({
        ...standardRoutes(),
        'GET /v1/family/invites': (_) => {'items': <dynamic>[]},
      });
      await tester.pumpWidget(ProviderScope(
        overrides: [apiClientProvider.overrideWithValue(api)],
        child: const FamilyShieldApp(),
      ));
      await tester.pumpAndSettle();

      // Sign in against the fake server (existing login flow).
      await tester.enterText(fieldByLabel('Server'), 'http://testserver');
      await tester.enterText(fieldByLabel('Email'), 'qa@familyshield.dev');
      await tester.enterText(fieldByLabel('Password'), 'good-password');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      expect(find.byType(DashboardScreen), findsOneWidget);

      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();
      expect(find.text('Family members'), findsOneWidget);
      await tester.tap(find.text('Family members'));
      await tester.pumpAndSettle();

      expect(find.byType(FamilyScreen), findsOneWidget);
      expect(find.text('Invite member'), findsOneWidget);
    });
  });

  group('Wind down (Feature #22)', () {
    FakeApiClient windDownApi() => FakeApiClient({
          ...standardRoutes(),
          'POST /v1/controls/children/child-1/wind-down': (_) => {'ok': true},
        });

    testWidgets('15/30 choice dialog POSTs {minutes} and confirms the countdown', (tester) async {
      final api = windDownApi();
      await pumpScreen(tester, const ChildDetailScreen(childId: 'child-1'), api);

      // NOTE: the first Scrollable is the (horizontal) TabBar's — target the
      // only vertical one, which belongs to the Overview ListView.
      final scrollable = find.byWidgetPredicate((w) => w is Scrollable && w.axis == Axis.vertical);
      await tester.scrollUntilVisible(find.widgetWithText(OutlinedButton, 'Wind down'), 100, scrollable: scrollable);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(OutlinedButton, 'Wind down'));
      await tester.pumpAndSettle();

      expect(find.text('The device shows a soft bedtime warning, then locks.'), findsOneWidget);
      await tester.tap(find.text('30 min'));
      await flushFakeHttp(tester);
      await tester.pumpAndSettle();

      final posts = api.calls('POST', '/v1/controls/children/child-1/wind-down');
      expect(posts, hasLength(1));
      expect(posts.single.body['minutes'], 30);
      expect(find.text('Screen will lock in 30 minutes on the device'), findsOneWidget);
      // Run out the snackbar so no timer is left pending at test end.
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    });
  });

  group('Geofence creation (Feature #23)', () {
    Future<void> openDialog(WidgetTester tester, FakeApiClient api) async {
      await tester.pumpWidget(ProviderScope(
        overrides: [apiClientProvider.overrideWithValue(api)],
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showGeofenceCreateDialog(
                  context,
                  children: const [Child(id: 'child-1', familyId: 'fam-1', displayName: 'Alex', birthYear: 2013)],
                  initialCenter: const LatLng(30.0444, 31.2357),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('switch on → POSTs geofence with routineId "school"', (tester) async {
      final api = FakeApiClient({
        ...standardRoutes(),
        'POST /v1/location/geofences': (_) => {'ok': true},
      });
      await openDialog(tester, api);

      await tester.enterText(fieldByLabel('Label (e.g. School)'), 'School');
      await tester.tap(find.widgetWithText(SwitchListTile, 'Apply school routine when here'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Create'));
      await flushFakeHttp(tester);
      await tester.pumpAndSettle();

      final posts = api.calls('POST', '/v1/location/geofences');
      expect(posts, hasLength(1));
      final body = posts.single.body;
      expect(body['childId'], 'child-1');
      expect(body['label'], 'School');
      expect(body['lat'], 30.0444);
      expect(body['lng'], 31.2357);
      expect(body['radiusM'], 250);
      expect(body['routineId'], 'school');
      expect(find.text('Geofence "School" added'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    });

    testWidgets('switch off → POSTs geofence without routineId', (tester) async {
      final api = FakeApiClient({
        ...standardRoutes(),
        'POST /v1/location/geofences': (_) => {'ok': true},
      });
      await openDialog(tester, api);

      await tester.enterText(fieldByLabel('Label (e.g. School)'), 'Home');
      await tester.tap(find.text('Create'));
      await flushFakeHttp(tester);
      await tester.pumpAndSettle();

      final body = api.calls('POST', '/v1/location/geofences').single.body;
      expect(body['label'], 'Home');
      expect(body.containsKey('routineId'), isFalse);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    });
  });

  group('Map bounds fit (Feature #21)', () {
    test('fitCameraToChildren no-ops without a controller or with one point', () async {
      // Guarded: in the widget-test env GoogleMap never attaches a controller.
      await fitCameraToChildren(null, const [LatLng(30.0, 31.0), LatLng(30.1, 31.1)]);
      await fitCameraToChildren(null, const [LatLng(30.0, 31.0)]);
      await fitCameraToChildren(null, const []);
    });
  });

  group('Vault trust copy (Feature #24)', () {
    testWidgets('concerns section shows the encryption banner', (tester) async {
      final api = FakeApiClient(standardRoutes());
      await pumpScreen(tester, const SocialScreen(childId: 'child-1'), api);

      expect(
        find.text('Snippets are encrypted with your family key before leaving the device and stored encrypted on your server.'),
        findsOneWidget,
      );
    });
  });
}
