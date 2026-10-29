import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:familyshield_parent/api/models.dart';
import 'package:familyshield_parent/features/children/child_detail_screen.dart';
import 'package:familyshield_parent/features/children/consent_step.dart';
import 'package:familyshield_parent/features/content/search_safety_screen.dart';
import 'package:familyshield_parent/features/content/snippet_vault_modal.dart';
import 'package:familyshield_parent/features/rules/rules_editor_screen.dart';
import 'package:familyshield_parent/features/dashboard/dashboard_screen.dart';
import 'package:familyshield_parent/l10n/app_localizations_ar.dart';
import 'package:familyshield_parent/features/onboarding/onboarding_messages.dart';
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

  Future<void> flushFakeHttp(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  group('Data Models', () {
    test('WebFilterRule defaults and serializes youtubeRestrictedMode', () {
      const defaultRule = WebFilterRule();
      expect(defaultRule.youtubeRestrictedMode, 'strict');
      expect(defaultRule.toJson()['youtubeRestrictedMode'], 'strict');

      final fromJson = WebFilterRule.fromJson({
        'blockedCategories': ['pornography'],
        'allowedDomains': ['example.com'],
        'blockedDomains': ['bad.com'],
        'safeSearchEnforced': true,
        'youtubeRestrictedMode': 'moderate',
      });
      expect(fromJson.youtubeRestrictedMode, 'moderate');
      expect(fromJson.toJson()['youtubeRestrictedMode'], 'moderate');

      final updated = fromJson.copyWith(youtubeRestrictedMode: 'off');
      expect(updated.youtubeRestrictedMode, 'off');
      expect(updated.blockedCategories, ['pornography']);
    });

    test('SearchEventItem parses and formats correctly', () {
      final now = DateTime.now().toUtc();
      final item = SearchEventItem.fromJson({
        'id': 'search-1',
        'engine': 'google',
        'query': 'how to bypass filter',
        'severity': 'critical',
        'concernTypes': ['bypass', 'security'],
        'createdAt': now.toIso8601String(),
      });
      expect(item.id, 'search-1');
      expect(item.engine, 'google');
      expect(item.query, 'how to bypass filter');
      expect(item.severity, 'critical');
      expect(item.concernTypes, ['bypass', 'security']);
      expect(item.createdAt?.toIso8601String(), now.toIso8601String());
      expect(item.toJson()['query'], 'how to bypass filter');
    });
  });

  group('SearchSafetyScreen', () {
    testWidgets('renders search query items from GET /v1/content/searches', (tester) async {
      final api = FakeApiClient({
        ...standardRoutes(),
        'GET /v1/content/searches': (req) => {
          'items': [
            {
              'id': 's-1',
              'engine': 'google',
              'query': 'how to buy vape',
              'severity': 'warning',
              'concernTypes': ['substance_use'],
              'createdAt': DateTime.now().subtract(const Duration(minutes: 5)).toIso8601String(),
            },
            {
              'id': 's-2',
              'engine': 'youtube',
              'query': 'dangerous stunt tutorial',
              'severity': 'critical',
              'concernTypes': ['violence'],
              'createdAt': DateTime.now().subtract(const Duration(hours: 1)).toIso8601String(),
            },
          ],
        },
      });

      await pumpScreen(tester, const SearchSafetyScreen(childId: 'child-1'), api);
      await flushFakeHttp(tester);
      await tester.pumpAndSettle();

      expect(find.text('Search safety'), findsOneWidget);
      expect(find.text('how to buy vape'), findsOneWidget);
      expect(find.text('dangerous stunt tutorial'), findsOneWidget);
      // The risk chips are localized now (#344 review): the raw server tag used to
      // reach the Arabic screen as "substance_use".
      expect(find.text('Substance use'), findsOneWidget);
      expect(find.text('Violence'), findsOneWidget);
      // The severity chip is translated now (#275): an Arabic screen showing CRITICAL in Latin
      // capitals was the last English string on this page, so the assertion follows the l10n key.
      expect(find.text('Warning'), findsOneWidget);
      expect(find.text('Critical'), findsOneWidget);
    });

    testWidgets('shows empty state when no flagged searches exist', (tester) async {
      final api = FakeApiClient({
        ...standardRoutes(),
        'GET /v1/content/searches': (_) => {'items': []},
      });

      await pumpScreen(tester, const SearchSafetyScreen(childId: 'child-1'), api);
      await flushFakeHttp(tester);
      await tester.pumpAndSettle();

      expect(find.text('No flagged searches detected'), findsOneWidget);
      expect(find.textContaining('SafeSearch enforcement'), findsOneWidget);
    });

    testWidgets('tapping search event opens SnippetVaultModal', (tester) async {
      final api = FakeApiClient({
        ...standardRoutes(),
        'GET /v1/content/searches': (_) => {
          'items': [
            {
              'id': 's-1',
              'engine': 'google',
              'query': 'secret proxy bypass',
              'severity': 'critical',
              'concernTypes': ['proxy'],
              'createdAt': DateTime.now().toIso8601String(),
            },
          ],
        },
      });

      await pumpScreen(tester, const SearchSafetyScreen(childId: 'child-1'), api);
      await flushFakeHttp(tester);
      await tester.pumpAndSettle();

      await tester.tap(find.text('secret proxy bypass'));
      await tester.pumpAndSettle();

      expect(find.text('Encrypted Family Vault'), findsOneWidget);
      expect(find.text('Decrypted content'), findsOneWidget);
      expect(find.text('secret proxy bypass'), findsWidgets);

      final coachFinder = find.text('How to talk about this');
      await tester.scrollUntilVisible(coachFinder, 150, scrollable: find.byType(Scrollable).last);
      await tester.pumpAndSettle();
      expect(coachFinder, findsOneWidget);
    });

    testWidgets('ChildDetailScreen AppBar action provides access to SearchSafetyScreen', (tester) async {
      final api = FakeApiClient(standardRoutes());
      await pumpScreen(tester, const ChildDetailScreen(childId: 'child-1'), api);
      await flushFakeHttp(tester);

      expect(find.byKey(const ValueKey('searchSafetyButton')), findsOneWidget);
    });
  });

  group('SnippetVaultModal', () {
    testWidgets('displays security trust banner, snippet, concern types, and coach card', (tester) async {
      await tester.pumpWidget(localizedTestApp(
        Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => SnippetVaultModal.show(
                context,
                title: 'Suspicious Search',
                snippet: 'how to hurt myself tonight',
                severity: 'critical',
                concernTypes: ['self_harm'],
                sourceLabel: 'GOOGLE',
                timestamp: DateTime.now(),
              ),
              child: const Text('Open Modal'),
            ),
          ),
        ),
      ));

      await tester.tap(find.text('Open Modal'));
      await tester.pumpAndSettle();

      expect(find.text('Encrypted Family Vault'), findsOneWidget);
      expect(find.textContaining('AES-256-GCM encryption'), findsOneWidget);
      expect(find.text('how to hurt myself tonight'), findsOneWidget);
      expect(find.text('Self-harm'), findsOneWidget);

      final coachFinder = find.text('How to talk about this');
      await tester.scrollUntilVisible(coachFinder, 150, scrollable: find.byType(Scrollable).last);
      await tester.pumpAndSettle();
      expect(coachFinder, findsOneWidget);

      // Expand the coach card ExpansionTile to reveal the language toggle
      await tester.tap(coachFinder);
      await tester.pumpAndSettle();

      // Verify bilingual coach card toggle
      final toggle = find.byKey(const ValueKey('coachLangToggle'));
      await tester.scrollUntilVisible(toggle, 150, scrollable: find.byType(Scrollable).last);
      await tester.pumpAndSettle();
      expect(toggle, findsOneWidget);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(find.text('كيف تتحدث مع طفلك عن هذا'), findsOneWidget);
    });
  });


  // #437 review point 1: the add-child dialog creates the child, so the generic consent sentences would
  // point at a page that does not exist yet. Its own sentence names the region the server expected, and
  // the code is mapped to a label so an Arabic sentence does not read «EU».
  test("the add-child consent refusal names the region, with the create route's real body", () {
    final options = RequestOptions(path: '/v1/family/children');
    DioException refusal(Map<String, dynamic> body) => DioException(
          requestOptions: options,
          response: Response(requestOptions: options, statusCode: 428, data: body),
          type: DioExceptionType.badResponse,
        );

    final arLocalizations = AppLocalizationsAr();
    final text = addChildConsentRegionError(
        arLocalizations, refusal({'error': 'consent_jurisdiction_mismatch', 'jurisdiction': 'EU'}));
    expect(text, isNotNull);
    expect(text, contains('يجب أن تطابق منطقة الموافقة منطقة عائلتك'));
    expect(text, contains(arLocalizations.regionEU),
        reason: 'the code is mapped to a label, so an Arabic sentence does not read «EU»');
    expect(text, isNot(contains('EU')));

    expect(addChildConsentRegionError(arLocalizations, refusal({'error': 'parental_consent_required'})), isNull,
        reason: 'the dialog has nothing to act on when consent is simply missing');
  });

  // #437 A2: the family-link pill is the main entry to pause/resume, so its refusal must read as a
  // sentence and never as our own type name (`ControlsRefusal(428)`).
  testWidgets('a refused pause from the family-link pill says why (#441)', (tester) async {
    final api = FakeApiClient({
      ...standardRoutes(),
      'POST /v1/controls/children/child-1/pause': (_) =>
          const FakeHttpError(428, {'error': 'parental_consent_required', 'childId': 'child-1'}),
    });
    await pumpScreen(tester, const DashboardScreen(), api);
    await flushFakeHttp(tester);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Internet').first);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Pause'));
    await flushFakeHttp(tester);
    await tester.pumpAndSettle();

    expect(api.calls('POST', '/v1/controls/children/child-1/pause'), hasLength(1));
    expect(
        find.text(
            "This change was not saved: this child has no active consent, so monitoring is paused. Open Parental consent on the child's page to see why."),
        findsOneWidget);
    expect(find.textContaining('ControlsRefusal'), findsNothing);
  });

  // #437 A2: the same region sentence on the onboarding wizard's create, which used to collapse every
  // 428 into "consent required" — sending a parent to ask for a consent the region had refused.
  test('the onboarding child error names the region on a 428 mismatch', () {
    final options = RequestOptions(path: '/v1/family/children');
    DioException refusal(Map<String, dynamic> body) => DioException(
          requestOptions: options,
          response: Response(requestOptions: options, statusCode: 428, data: body),
          type: DioExceptionType.badResponse,
        );
    final arLocalizations = AppLocalizationsAr();
    final text = onboardingChildError(
        arLocalizations, refusal({'error': 'consent_jurisdiction_mismatch', 'jurisdiction': 'EU'}));
    expect(text, contains(arLocalizations.regionEU));
    expect(text, isNot(equals(arLocalizations.onboardingConsentRequired)),
        reason: 'a region mismatch is actionable; "consent required" is not the same sentence');
    expect(
        onboardingChildError(arLocalizations, refusal({'error': 'parental_consent_required'})),
        arLocalizations.onboardingConsentRequired);
  });

  // #437 part B: the add-child dialog asks for consent through the shared `ConsentStep`, so the
  // notice cannot drift from the consent screen's copy. Claude's fault 4: reverting to an inline
  // text block with the notice removed must turn this red (`find.byType(ConsentStep)` finds nothing),
  // which is what makes the row evidence that the shared widget is the one on screen.
  testWidgets('the add-child dialog asks for consent through the shared ConsentStep',
      (tester) async {
    final api = FakeApiClient({...standardRoutes()});
    await pumpScreen(tester, const Scaffold(body: AddChildDialog()), api);

    expect(find.byType(ConsentStep), findsOneWidget);
    expect(
        find.text(
            'Before you add a child, we need to confirm that you are their parent or guardian.'),
        findsOneWidget);

    // The method chosen through the shared widget is the one that gets posted, so the extraction
    // did not sever the wiring between the step and the dialog's own state.
    await tester.tap(find.byKey(const ValueKey('consentMethod')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Face match').last);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Child name'), 'Alex');
    await tester.enterText(find.widgetWithText(TextField, 'Birth year'), '2014');
    await tester.tap(find.widgetWithText(FilledButton, 'Add child'));
    await flushFakeHttp(tester);

    expect(
      api.calls('POST', '/v1/family/children').single.body['consent'],
      {'method': 'face_match', 'jurisdiction': 'US'},
    );
  });

  // #437 part A: the add-child dialog shows the region sentence when the create route refuses the
  // consent region (`family.ts:148`), not the wire code.
  testWidgets('a region refusal on add child names the family region in the dialog', (tester) async {
    final api = FakeApiClient({
      ...standardRoutes(),
      'POST /v1/family/children': (_) =>
          const FakeHttpError(428, {'error': 'consent_jurisdiction_mismatch', 'jurisdiction': 'EU'}),
    });
    await pumpScreen(tester, const Scaffold(body: AddChildDialog()), api);

    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Child name'), 'Alex');
    await tester.enterText(find.widgetWithText(TextField, 'Birth year'), '2014');
    await tester.tap(find.widgetWithText(FilledButton, 'Add child'));
    await flushFakeHttp(tester);

    expect(
        find.text("The consent region must match your family's region (European Union). "
            'Choose European Union and try again.'),
        findsOneWidget);
    expect(find.textContaining('consent_jurisdiction_mismatch'), findsNothing);
  });

  // #437 part A: a rule save refused for consent shows the sentence in the editor's banner, not the
  // wire code. The body is the one `requireConsent` sends (`middleware/requireConsent.ts:51`).
  testWidgets('a 428 on a rule save says why in the banner, not the raw code', (tester) async {
    final api = FakeApiClient({
      ...standardRoutes(),
      'PUT /v1/rules/child-1': (_) => const FakeHttpError(428, {'error': 'parental_consent_required'}),
    });
    await pumpScreen(tester, const RulesEditorScreen(childId: 'child-1'), api);
    await flushFakeHttp(tester);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Save'));
    await flushFakeHttp(tester);
    await tester.pumpAndSettle();

    expect(api.calls('PUT', '/v1/rules/child-1'), hasLength(1));
    expect(
      find.descendant(
        of: find.byType(MaterialBanner),
        matching: find.text(
            "This change was not saved: this child has no active consent, so monitoring is paused. Open Parental consent on the child's page to see why."),
      ),
      findsOneWidget,
    );
    expect(find.textContaining('parental_consent_required'), findsNothing);
  });

  group('YouTube Restricted Mode in RulesEditorScreen', () {
    testWidgets('renders segmented control and saves selected mode', (tester) async {
      final api = FakeApiClient({
        ...standardRoutes(),
        'GET /v1/rules/child-1': (_) => ruleSetPayload('child-1', webFilter: {
          'blockedCategories': ['pornography'],
          'allowedDomains': [],
          'blockedDomains': [],
          'safeSearchEnforced': true,
          'youtubeRestrictedMode': 'strict',
        }),
        'PUT /v1/rules/child-1': (req) => req.body,
      });

      await pumpScreen(tester, const RulesEditorScreen(childId: 'child-1'), api);
      await flushFakeHttp(tester);
      await tester.pumpAndSettle();

      // Switch to Web filter tab
      await tester.tap(find.text('Web filter'));
      await tester.pumpAndSettle();

      final ytSection = find.text('YouTube Restricted Mode');
      final scrollable = find.descendant(
        of: find.byKey(const ValueKey('webFilterList')),
        matching: find.byWidgetPredicate((w) => w is Scrollable && w.axis == Axis.vertical),
      );
      await tester.scrollUntilVisible(ytSection, 150, scrollable: scrollable);
      await tester.pumpAndSettle();

      expect(ytSection, findsOneWidget);
      expect(find.text('Strict'), findsOneWidget);
      expect(find.text('Moderate'), findsOneWidget);
      expect(find.text('Off'), findsOneWidget);

      // Select Moderate
      await tester.tap(find.text('Moderate'));
      await tester.pumpAndSettle();

      // Save
      await tester.tap(find.text('Save'));
      await flushFakeHttp(tester);
      await tester.pumpAndSettle();

      final puts = api.calls('PUT', '/v1/rules/child-1');
      expect(puts, hasLength(1));
      final webFilter = Map<String, dynamic>.from(puts.single.body['webFilter'] as Map);
      expect(webFilter['youtubeRestrictedMode'], 'moderate');
    });

    testWidgets('renders off selected when API returns off on reload', (tester) async {
      final api = FakeApiClient({
        ...standardRoutes(),
        'GET /v1/rules/child-1': (_) => ruleSetPayload('child-1', webFilter: {
          'blockedCategories': ['pornography'],
          'allowedDomains': [],
          'blockedDomains': [],
          'safeSearchEnforced': true,
          'youtubeRestrictedMode': 'off',
        }),
      });

      await pumpScreen(tester, const RulesEditorScreen(childId: 'child-1'), api);
      await flushFakeHttp(tester);
      await tester.pumpAndSettle();

      // Switch to Web filter tab
      await tester.tap(find.text('Web filter'));
      await tester.pumpAndSettle();

      final ytSection = find.text('YouTube Restricted Mode');
      final scrollable = find.descendant(
        of: find.byKey(const ValueKey('webFilterList')),
        matching: find.byWidgetPredicate((w) => w is Scrollable && w.axis == Axis.vertical),
      );
      await tester.scrollUntilVisible(ytSection, 150, scrollable: scrollable);
      await tester.pumpAndSettle();

      final segmentedButtonFinder = find.byType(SegmentedButton<String>);
      expect(segmentedButtonFinder, findsOneWidget);
      final segmentedButton = tester.widget<SegmentedButton<String>>(segmentedButtonFinder);
      expect(segmentedButton.selected, equals({'off'}));
    });
  });
}
