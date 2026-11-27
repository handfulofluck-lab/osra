import 'package:familyshield_parent/api/models.dart' as models;
import 'package:familyshield_parent/features/children/add_child_p04_screen.dart';
import 'package:familyshield_parent/features/dashboard/dashboard_screen.dart';
import 'package:familyshield_parent/features/onboarding/setup_child_screen.dart';
import 'package:familyshield_parent/l10n/l10n.dart';
import 'package:familyshield_parent/providers/auth_provider.dart';
import 'package:familyshield_parent/providers/clock_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_api_client.dart';
import 'test_app.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final en = lookupAppLocalizations(const Locale('en'));

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  List<RecordedRequest> posts(FakeApiClient api) => api.requests
      .where((r) => r.method == 'POST' && r.path == '/v1/family/children')
      .toList();

  Future<void> pumpForm(
    WidgetTester tester,
    FakeApiClient api, {
    String region = 'EU',
    Locale locale = const Locale('en'),
    ValueChanged<String>? onCreated,
  }) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        clockProvider.overrideWithValue(() => DateTime(2026, 11, 27)),
      ],
      child: localizedTestApp(
        Scaffold(
          body: AddChildP04Form(
            jurisdiction: region,
            onCreated: onCreated ?? (_) {},
          ),
        ),
        locale: locale,
      ),
    ));
    await tester.pumpAndSettle();
  }

  Future<void> fillValid(WidgetTester tester) async {
    await tester.enterText(find.byKey(const ValueKey('p04ChildName')), 'Alex');
    await tester.enterText(find.byKey(const ValueKey('p04ChildAge')), '12');
  }

  Future<void> submit(WidgetTester tester) async {
    await tester.ensureVisible(find.byKey(const ValueKey('p04Submit')));
    await tester.tap(find.byKey(const ValueKey('p04Submit')));
    await tester.pumpAndSettle();
  }

  testWidgets(
      'unticked guardian affirmation posts nothing and has no jurisdiction picker',
      (tester) async {
    final api = FakeApiClient(standardRoutes());
    await pumpForm(tester, api);
    await fillValid(tester);
    await submit(tester);

    expect(posts(api), isEmpty);
    expect(find.byKey(const ValueKey('p04ConsentError')), findsOneWidget);
    expect(find.text(en.p04GuardianRequired), findsOneWidget);
    expect(find.byKey(const ValueKey('onboardingJurisdiction')), findsNothing);
    expect(find.byKey(const ValueKey('addChildJurisdiction')), findsNothing);
  });

  testWidgets(
      'blank, zero, eighteen and non-numeric ages never fall back to the current year',
      (tester) async {
    final api = FakeApiClient(standardRoutes());
    await pumpForm(tester, api);
    for (final age in ['', '0', '18', 'not-a-number']) {
      await tester.enterText(
          find.byKey(const ValueKey('p04ChildName')), 'Alex');
      await tester.enterText(find.byKey(const ValueKey('p04ChildAge')), age);
      await submit(tester);
      expect(posts(api), isEmpty, reason: 'age $age');
      final field =
          tester.widget<TextField>(find.byKey(const ValueKey('p04ChildAge')));
      expect(
        field.decoration?.errorText,
        'Enter an age from \u{2066}1\u{2069} to \u{2066}17\u{2069}.',
        reason: 'age $age',
      );
    }
  });

  testWidgets('leaving a field validates that field without posting', (tester) async {
    final api = FakeApiClient(standardRoutes());
    await pumpForm(tester, api);
    await tester.tap(find.byKey(const ValueKey('p04ChildName')));
    await tester.tap(find.byKey(const ValueKey('p04ChildAge')));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byKey(const ValueKey('p04ChildName'))).decoration?.errorText,
      en.onboardingChildNameRequired,
    );

    await tester.enterText(find.byKey(const ValueKey('p04ChildAge')), '0');
    await tester.tap(find.byKey(const ValueKey('p04ChildName')));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byKey(const ValueKey('p04ChildAge'))).decoration?.errorText,
      'Enter an age from \u{2066}1\u{2069} to \u{2066}17\u{2069}.',
    );
    expect(posts(api), isEmpty);
  });

  testWidgets('valid non-US submission sends the exact body once',
      (tester) async {
    final api = FakeApiClient(standardRoutes());
    String? createdId;
    await pumpForm(tester, api,
        region: 'EU', onCreated: (id) => createdId = id);
    await fillValid(tester);
    await tester.ensureVisible(find.byType(CheckboxListTile));
    await tester.tap(find.byType(CheckboxListTile));
    await submit(tester);

    expect(createdId, 'child-new');
    expect(posts(api), hasLength(1));
    expect(posts(api).single.body, {
      'displayName': 'Alex',
      'birthYear': 2014,
      'consent': {'method': 'sms_plus', 'jurisdiction': 'EU'},
    });
  });

  testWidgets(
      'privacy opens a sheet without consent, navigation, or losing the form',
      (tester) async {
    final api = FakeApiClient(standardRoutes());
    await pumpForm(tester, api);
    await tester.enterText(find.byKey(const ValueKey('p04ChildName')), 'Alex');
    await tester.ensureVisible(find.byKey(const ValueKey('p04CollectedLink')));
    await tester.tap(find.byKey(const ValueKey('p04CollectedLink')));
    await tester.pumpAndSettle();

    expect(find.text(en.onboardingChildPrivacy), findsOneWidget);
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(posts(api), isEmpty);
    await tester.tap(find.text(en.close));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsNothing);
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('p04ChildName')))
          .controller
          ?.text,
      'Alex',
    );
    expect(find.byType(CheckboxListTile), findsOneWidget);
  });

  testWidgets(
      'closing and reopening starts empty and writes no draft preferences',
      (tester) async {
    final api = FakeApiClient(standardRoutes());
    await pumpForm(tester, api);
    await tester.enterText(find.byKey(const ValueKey('p04ChildName')), 'Alex');
    await tester.pumpWidget(const SizedBox());
    await pumpForm(tester, api);

    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('p04ChildName')))
          .controller
          ?.text,
      isEmpty,
    );
    expect(posts(api), isEmpty);
    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs
          .getKeys()
          .where((key) => key.contains('p04') || key.contains('draft')),
      isEmpty,
    );
  });

  testWidgets('wizard uses the same P-04 form behind the flag', (tester) async {
    final api = FakeApiClient({
      ...standardRoutes(),
      'GET /v1/family/me': (_) => {
            ...familyMeTwoChildren(),
            'children': <Map<String, dynamic>>[],
          },
    });
    final family =
        models.Family.fromJson({'id': 'fam-1', 'name': 'QA', 'region': 'EU'});
    await tester.pumpWidget(ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        authProvider.overrideWith((ref) => _SignedInNotifier(api, family)),
        p04AddChildEnabledProvider.overrideWithValue(true),
        clockProvider.overrideWithValue(() => DateTime(2026, 11, 27)),
      ],
      child: localizedTestApp(const SetupChildScreen()),
    ));
    await tester.pumpAndSettle();

    expect(find.byType(AddChildP04Form), findsOneWidget);
    expect(find.byKey(const ValueKey('p04ChildAge')), findsOneWidget);
    expect(find.byKey(const ValueKey('onboardingBirthYear')), findsNothing);
    expect(find.byKey(const ValueKey('onboardingJurisdiction')), findsNothing);
  });

  testWidgets(
      'dashboard opener uses the shared screen only when the flag is on',
      (tester) async {
    final api = FakeApiClient(standardRoutes());
    final family =
        models.Family.fromJson({'id': 'fam-1', 'name': 'QA', 'region': 'UK'});
    Future<void> pumpOpener(bool enabled) => tester.pumpWidget(ProviderScope(
          overrides: [
            apiClientProvider.overrideWithValue(api),
            authProvider.overrideWith((ref) => _SignedInNotifier(api, family)),
            p04AddChildEnabledProvider.overrideWithValue(enabled),
          ],
          child: localizedTestApp(Scaffold(
            body: Consumer(
              builder: (context, ref, _) => FilledButton(
                onPressed: () => openAddChildFlow(context, ref),
                child: const Text('Open'),
              ),
            ),
          )),
        ));

    await pumpOpener(false);
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.byType(AddChildDialog), findsOneWidget);
    expect(find.byType(AddChildP04Screen), findsNothing);
    await tester.tap(find.text(en.cancel));
    await tester.pumpAndSettle();

    await pumpOpener(true);
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.byType(AddChildP04Screen), findsOneWidget);
    expect(find.text(en.p04AddTitle), findsOneWidget);
  });

  // Mutant: reverting `labelText: l10n.p04AgeLabel` back to `l10n.p04AgeRange(...)`
  // fails `find.text('Age')` and duplicates the range sentence twice on invalid age (B1).
  testWidgets(
      'B1 Age field uses short Age label with number keyboard and shows range sentence once as error',
      (tester) async {
    final api = FakeApiClient(standardRoutes());
    await pumpForm(tester, api);

    final ageField =
        tester.widget<TextField>(find.byKey(const ValueKey('p04ChildAge')));
    expect(ageField.keyboardType, TextInputType.number);
    expect(find.text(en.p04AgeLabel), findsOneWidget);
    expect(find.textContaining('Enter an age from'), findsNothing);

    await tester.enterText(find.byKey(const ValueKey('p04ChildAge')), '99');
    await tester.ensureVisible(find.byKey(const ValueKey('p04Submit')));
    await tester.tap(find.byKey(const ValueKey('p04Submit')));
    await tester.pumpAndSettle();

    expect(find.text(en.p04AgeLabel), findsOneWidget);
    expect(find.textContaining('Enter an age from'), findsOneWidget);
  });

  testWidgets('Arabic catalog carries the same P-04 keys and age placeholders',
      (tester) async {
    final ar = lookupAppLocalizations(const Locale('ar'));
    expect(ar.p04AgeLabel, 'العمر');
    expect(ar.p04WhatWeCollect, isNotEmpty);
    expect(ar.p04GuardianConfirm, isNotEmpty);
    expect(ar.p04GuardianRequired, isNotEmpty);
    expect(ar.p04AddTitle, isNotEmpty);
    expect(ar.p04AgeRange('1', '17'), contains('1'));
    expect(ar.p04AgeRange('1', '17'), contains('17'));
  });
}

class _SignedInNotifier extends AuthNotifier {
  _SignedInNotifier(FakeApiClient api, models.Family family) : super(api) {
    state = AuthState(isAuthenticated: true, family: family);
  }
}
