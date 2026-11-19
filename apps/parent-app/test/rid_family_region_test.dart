import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Prefixed: riverpod exports its own `Family` (the provider family type).
import 'package:familyshield_parent/api/models.dart' as models;
import 'package:familyshield_parent/features/children/consent_screen.dart';
import 'package:familyshield_parent/features/children/consent_step.dart';
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

  group('B6 at 320 px / 200 % (#874, UI/UX Bureau)', () {
    /// Sets a 320 px surface at 200 % text for the duration of one test.
    void narrowAndLarge(WidgetTester tester) {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1.0;
      tester.platformDispatcher.textScaleFactorTestValue = 2.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        tester.platformDispatcher.clearTextScaleFactorTestValue();
      });
    }

    /// The `DropdownButton` a form field builds, which is where `isExpanded` and `selectedItemBuilder`
    /// actually live: the form-field widget passes both straight through and stores neither.
    DropdownButton<String> buttonFor(WidgetTester tester, Key fieldKey) => tester.widget<DropdownButton<String>>(
          find.descendant(of: find.byKey(fieldKey), matching: find.byType(DropdownButton<String>)),
        );

    /// Every widget a `selectedItemBuilder` returns must be allowed to wrap: no `maxLines`, no ellipsis.
    void expectMayWrap(WidgetTester tester, DropdownButton<String> button, Key fieldKey) {
      final items = button.selectedItemBuilder!(tester.element(find.byKey(fieldKey)));
      expect(items, isNotEmpty);
      for (final item in items) {
        expect(item, isA<Text>());
        final text = item as Text;
        expect(text.maxLines, isNull, reason: 'a capped line count is how the label was cut');
        expect(text.overflow, isNot(TextOverflow.ellipsis), reason: 'the Bureau refused the ellipsis');
      }
    }

    testWidgets('the add-child region picker expands and its chosen place may wrap', (tester) async {
      narrowAndLarge(tester);
      await pumpSignedIn(tester, const Scaffold(body: AddChildDialog()));
      // Mutant: drop `isExpanded: true` and the 200 % frame overflows by 27 px (82 px at 320/200 %); this
      // row is the code fact, the frames are the picture.
      final button = buttonFor(tester, const ValueKey('addChildJurisdiction'));
      expect(button.isExpanded, isTrue);
      expect(button.selectedItemBuilder, isNotNull);
      expectMayWrap(tester, button, const ValueKey('addChildJurisdiction'));
      expect(tester.takeException(), isNull, reason: 'the dialog lays out at 320 px / 200 %');
    });

    testWidgets('the consent-method picker expands and «رسالة نصية مع تأكيد» may wrap', (tester) async {
      narrowAndLarge(tester);
      await tester.pumpWidget(ProviderScope(
        overrides: [apiClientProvider.overrideWithValue(FakeApiClient(standardRoutes()))],
        child: localizedTestApp(
          Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(8),
              child: ConsentStep(method: kConsentMethods.first, onMethodChanged: (_) {}),
            ),
          ),
          locale: const Locale('ar'),
          textDirection: TextDirection.rtl,
        ),
      ));
      await tester.pumpAndSettle();

      final button = buttonFor(tester, const ValueKey('consentMethod'));
      expect(button.isExpanded, isTrue);
      expect(button.selectedItemBuilder, isNotNull);
      expectMayWrap(tester, button, const ValueKey('consentMethod'));
      expect(tester.takeException(), isNull);
    });

    testWidgets('the question sits above the field and is laid out whole', (tester) async {
      // Antigravity's finding at `50aad293`: `FieldQuestion` had two surviving mutants. This row kills
      // the first — `maxLines: 1` + `TextOverflow.ellipsis` on the heading, which is exactly what Flutter
      // does to `InputDecoration.labelText` and what made the dialog read "Consent meth…".
      narrowAndLarge(tester);
      await pumpSignedIn(tester, const Scaffold(body: AddChildDialog()));

      final l10n = lookupAppLocalizations(const Locale('en'));
      final heading = find.text(l10n.jurisdictionLabel);
      expect(heading, findsOneWidget, reason: 'the question is a widget of its own, above the field');

      final paragraph = tester.renderObject<RenderParagraph>(heading);
      final neededWidth = paragraph.getMaxIntrinsicWidth(double.infinity);
      final neededHeight = paragraph.getMaxIntrinsicHeight(paragraph.size.width);
      expect(paragraph.didExceedMaxLines, isFalse, reason: 'ellipsised — this is the defect again');
      final fitsWidth = paragraph.size.width + 0.5 >= neededWidth;
      final fitsHeight = paragraph.size.height + 0.5 >= neededHeight;
      expect(fitsWidth || fitsHeight, isTrue,
          reason: 'box ${paragraph.size} needs ${neededWidth}x$neededHeight');
    });

    testWidgets('the field carries the question as its accessible name, exactly once', (tester) async {
      // Antigravity's second mutant: deleting `Semantics(label: text, child: child)`. The visible heading
      // is inside `ExcludeSemantics`, so without that wrapper a screen reader hears the question zero
      // times — and with it, once, on the control itself.
      narrowAndLarge(tester);
      final handle = tester.ensureSemantics();
      await pumpSignedIn(tester, const Scaffold(body: AddChildDialog()));

      final l10n = lookupAppLocalizations(const Locale('en'));
      expect(
        find.bySemanticsLabel(RegExp(RegExp.escape(l10n.jurisdictionLabel))),
        findsOneWidget,
        reason: 'the question must reach a screen reader once, on the field',
      );
      handle.dispose(); // before the test ends: the framework rejects a leaked handle
    });

    testWidgets('"Add child and continue" is a 52 px full-width button with a centred label', (tester) async {
      narrowAndLarge(tester);
      await pumpSignedIn(tester, const SetupChildScreen());
      // The screen is a lazy ListView and the button is below the fold at 320 px / 200 %, so it is not
      // built until it is scrolled to. Scrolling first is also the honest frame the Bureau measured.
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('onboardingAddChild')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();

      final button = tester.widget<FilledButton>(find.byKey(const ValueKey('onboardingAddChild')));
      final size = button.style?.minimumSize?.resolve(<WidgetState>{});
      // Mutant: drop the style and the label wraps into the rounded edge at the largest text.
      expect(size?.height, 52);
      expect(size?.width, double.infinity, reason: 'Size.fromHeight: full width, a floor on height only');

      final label = tester.widget<Text>(find.descendant(
        of: find.byKey(const ValueKey('onboardingAddChild')),
        matching: find.text(lookupAppLocalizations(const Locale('en')).onboardingAddChildContinue),
      ));
      expect(label.textAlign, TextAlign.center);
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
