import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Prefixed: riverpod exports its own `Family` (the provider family type).
import 'package:familyshield_parent/api/models.dart' as models;
import 'package:familyshield_parent/features/children/consent_screen.dart';
import 'package:familyshield_parent/features/dashboard/dashboard_screen.dart';
import 'package:familyshield_parent/features/onboarding/setup_child_screen.dart';
import 'package:familyshield_parent/l10n/l10n.dart';
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

  /// Advances Dio's chained zero-duration timers so the fake answers land inside the test.
  Future<void> flushFakeHttp(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  /// Pumps a screen behind a session that is already signed in, so it can read the family's region at
  /// construction. `AuthNotifier.bootstrap()` would be the honest route, but awaiting it here deadlocks —
  /// the fake client's timers only advance inside `tester.pump`, and the await happens before there is a
  /// tree to pump. The assertion is about which region the picker starts on, not about bootstrap.
  Future<void> pumpSignedIn(WidgetTester tester, Widget home, {String region = 'EU'}) async {
    final family = models.Family.fromJson({'id': 'fam-1', 'name': 'QA Family', 'region': region});
    final api = FakeApiClient({
      ...standardRoutes(),
      // No children yet, so the onboarding screen renders its form instead of the "add another" list —
      // the jurisdiction picker lives in the form.
      'GET /v1/family/me': (_) => {
            ...familyMeTwoChildren(),
            'family': {'id': 'fam-1', 'name': 'QA Family', 'region': region},
            'children': <Map<String, dynamic>>[],
          },
    });
    await tester.pumpWidget(ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        authProvider.overrideWith((ref) => _SignedInNotifier(api, family)),
      ],
      child: localizedTestApp(home),
    ));
    await flushFakeHttp(tester);
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

  /// R-ID-4, the same defect one screen over (Kimi, 04:41Z): the consent screen printed the raw codes,
  /// both in its "Jurisdiction" field and inside the mismatch sentence. Both now go through one mapping
  /// that reuses the picker's own words — no new string, and a value the app does not know becomes
  /// "Other" rather than being echoed.
  group('regionPlaceName', () {
    final en = lookupAppLocalizations(const Locale('en'));

    test('names the four regions the API issues', () {
      expect(regionPlaceName(en, 'US'), 'United States');
      expect(regionPlaceName(en, 'EU'), 'European Union');
      expect(regionPlaceName(en, 'UK'), 'United Kingdom');
      expect(regionPlaceName(en, 'OTHER'), 'Other');
    });

    test('is case- and space-tolerant, because the value comes from the server', () {
      expect(regionPlaceName(en, ' eu '), 'European Union');
      expect(regionPlaceName(en, 'uk'), 'United Kingdom');
    });

    test('never echoes an unknown code back to the parent', () {
      // Mutant: `_ => code` and this row goes red, as does the "no code on screen" claim of the row above.
      expect(regionPlaceName(en, 'ZZ'), 'Other');
      expect(regionPlaceName(en, ''), 'Other');
    });
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
  _SignedInNotifier(FakeApiClient api, models.Family family) : super(api) {
    state = AuthState(isAuthenticated: true, family: family);
  }
}
