import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:familyshield_parent/api/models.dart';
import 'package:familyshield_parent/features/dashboard/dashboard_screen.dart';
import 'package:familyshield_parent/features/onboarding/setup_child_screen.dart';
import 'package:familyshield_parent/providers/auth_provider.dart';

import 'fake_api_client.dart';
import 'test_app.dart';

/// R-ID-4 (#650, 6925069781): the consent picker was "Jurisdiction" — legal jargon — with US / EU / UK
/// codes behind it, and every family started on the United States.
///
/// Mutants: put the old label back and the two label rows go red; make the initial value `'US'` again
/// and "preselects the family's own region" goes red for a family whose region is EU or UK.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // Secure storage and preferences are still mocked: the screens and the providers they watch read both.
    FlutterSecureStorage.setMockInitialValues({'jwt': 'jwt-token'});
    SharedPreferences.setMockInitialValues({});
  });

  /// A session that is already signed in, so the screens can read the family's region at construction.
  ///
  /// `AuthNotifier.bootstrap()` would be the honest route, but awaiting it here deadlocks: the fake HTTP
  /// client dispatches through chained zero-duration timers that only advance inside `tester.pump`, and the
  /// await happens before there is a tree to pump. Setting the state on a subclass keeps the test off the
  /// clock entirely — the assertion is about which region the picker starts on, not about bootstrap.
  Future<void> pumpSignedIn(WidgetTester tester, Widget home, {String region = 'EU'}) async {
    final api = FakeApiClient(standardRoutes());
    final family = Family.fromJson({'id': 'fam-1', 'name': 'QA Family', 'region': region});
    await tester.pumpWidget(ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        authProvider.overrideWith((ref) => _SignedInNotifier(api, family)),
      ],
      child: localizedTestApp(home),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('the onboarding consent picker asks where the family lives, in plain words', (tester) async {
    await pumpSignedIn(tester, const SetupChildScreen());
    expect(find.text('Where does your family live?'), findsOneWidget);
    // The jargon and the codes are gone from the screen.
    expect(find.text('Jurisdiction'), findsNothing);
    expect(find.text('EU'), findsNothing);
  });

  testWidgets('the onboarding picker preselects the family region chosen at sign-up', (tester) async {
    await pumpSignedIn(tester, const SetupChildScreen(), region: 'EU');
    // The closed dropdown shows the selected place, not the code.
    expect(find.text('European Union'), findsOneWidget);
    expect(find.text('United States'), findsNothing);
  });

  testWidgets('the dashboard add-child dialog asks the same question and preselects too', (tester) async {
    await pumpSignedIn(tester, const Scaffold(body: AddChildDialog()), region: 'UK');
    expect(find.text('Where does your family live?'), findsOneWidget);
    expect(find.text('United Kingdom'), findsOneWidget);
    expect(find.text('United States'), findsNothing);
    expect(find.text('UK'), findsNothing);
  });

  testWidgets('a family registered in the United States still sees its own answer', (tester) async {
    // The row that would pass for the wrong reason if the default were hard-coded: US is both the old
    // constant and this family's region, so the assertion is on the selected place, not on its absence.
    await pumpSignedIn(tester, const Scaffold(body: AddChildDialog()), region: 'US');
    expect(find.text('United States'), findsOneWidget);
    expect(find.text('Where does your family live?'), findsOneWidget);
  });
}

/// An `AuthNotifier` whose session is already loaded. `state` is settable from a subclass, which is the
/// smallest way to hand a widget a signed-in family without touching the network or the fake clock.
class _SignedInNotifier extends AuthNotifier {
  _SignedInNotifier(FakeApiClient api, Family family) : super(api) {
    state = AuthState(isAuthenticated: true, family: family);
  }
}
