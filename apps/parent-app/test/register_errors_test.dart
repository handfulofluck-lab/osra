import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:familyshield_parent/features/auth/auth_messages.dart';
import 'package:familyshield_parent/features/auth/create_account_screen.dart';
import 'package:familyshield_parent/l10n/l10n.dart';
import 'package:familyshield_parent/providers/auth_provider.dart';
import 'package:familyshield_parent/providers/onboarding_provider.dart';

import 'fake_api_client.dart';
import 'test_app.dart';

/// ADR-0043 D6, part B (counsel's 16 Nov scope): sign-up is its own page with one required consent box.
/// These rows keep the register-form behaviour that #161/#189 established — the rule is stated, a short
/// password or missing name is caught before the request, a server rejection names its field — and add the
/// consent contract: the sentence and links come from `GET /v1/consent-copy`, the box is required, and the
/// register payload carries the `textVersion` it showed.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({kOnboardingCompleteKey: true});
  });

  const validPassword = 'twelve-chars-ok';
  final en = lookupAppLocalizations(const Locale('en'));

  // Counsel's final English (publication pack 16 Nov, doc 09 A1), byte for byte.
  const englishBox =
      'I am an adult and the parent, legal guardian or other person legally allowed to care for each child I add to OSRA. I accept the OSRA [Terms of Use](https://osratech.com/terms) and I have read the [Privacy Policy](https://osratech.com/privacy).';

  Map<String, dynamic> copy({String text = englishBox}) => {
        'textVersion': 'signup-v1',
        'purposes': [
          {
            'key': 'terms_privacy',
            'required': true,
            'text': text,
            'textHash': 'sha256-of-the-english-box',
            'links': {
              'terms': 'https://osratech.com/terms',
              'privacy': 'https://osratech.com/privacy',
            },
          },
        ],
      };

  Finder fieldByLabel(String label) => find.ancestor(of: find.text(label), matching: find.byType(TextField));

  Future<void> pumpSignUp(WidgetTester tester, FakeApiClient api, {Locale locale = const Locale('en')}) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(ProviderScope(
      overrides: [apiClientProvider.overrideWithValue(api)],
      child: localizedTestApp(const CreateAccountScreen(), locale: locale),
    ));
    await tester.pumpAndSettle();
  }

  Future<FakeApiClient> api({Map<String, dynamic>? copyBody}) async {
    return FakeApiClient({
      ...standardRoutes(),
      'GET /v1/consent-copy': (_) => copyBody ?? copy(),
    });
  }

  Future<void> fillForm(
    WidgetTester tester, {
    String email = 'new@osratech.com',
    String password = validPassword,
    String familyName = 'Rivera',
    String displayName = 'Sam',
  }) async {
    await tester.enterText(fieldByLabel('Family name'), familyName);
    await tester.enterText(fieldByLabel('Your name'), displayName);
    await tester.enterText(fieldByLabel('Email'), email);
    await tester.enterText(fieldByLabel('Password'), password);
  }

  Future<void> tapCreate(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('createAccountButton')));
    await tester.pumpAndSettle();
  }

  String? shown(WidgetTester tester, String key) {
    final f = find.byKey(ValueKey(key));
    return f.evaluate().isEmpty ? null : (tester.widget<Text>(f).data);
  }

  Map<String, FakeRoute> withRegister(FakeRoute register) => {
        'POST /v1/auth/register': register,
        'GET /v1/consent-copy': (_) => copy(),
      };

  group('sign-up form', () {
    testWidgets('the consent box shows the copy sentence without markdown, and its two links as buttons', (tester) async {
      await pumpSignUp(tester, await api());

      final label = shown(tester, 'consentTermsText')!;
      expect(label, contains('I am an adult and the parent'));
      expect(label, isNot(contains('[')), reason: 'markdown brackets are not shown');
      expect(label, isNot(contains('http')), reason: 'the link is a button, not text');
      expect(find.byKey(const ValueKey('consentTermsLink')), findsOneWidget);
      expect(find.byKey(const ValueKey('consentPrivacyLink')), findsOneWidget);
      expect(find.text('Terms of Use'), findsOneWidget);
      expect(find.text('Privacy Policy'), findsOneWidget);
    });

    testWidgets('the links are outside the tappable row, so a link tap cannot tick the box', (tester) async {
      await pumpSignUp(tester, await api());
      expect(
        find.descendant(of: find.byType(CheckboxListTile), matching: find.byKey(const ValueKey('consentTermsLink'))),
        findsNothing,
      );
      expect(
        find.descendant(of: find.byType(CheckboxListTile), matching: find.byKey(const ValueKey('consentPrivacyLink'))),
        findsNothing,
      );
    });

    testWidgets('pressing create without ticking names the box, not the fields, and sends nothing', (tester) async {
      final client = await api();
      await pumpSignUp(tester, client);
      await fillForm(tester);
      await tapCreate(tester);

      expect(shown(tester, 'consentError'), en.consentRequired);
      expect(shown(tester, 'registerError'), isNull);
      expect(client.calls('POST', '/v1/auth/register'), isEmpty);
      final button = tester.widget<FilledButton>(find.byKey(const ValueKey('createAccountButton')));
      expect(button.onPressed, isNotNull, reason: 'the button is never greyed out as the answer');
    });

    testWidgets('the error is announced as a live region under the box', (tester) async {
      await pumpSignUp(tester, await api());
      await fillForm(tester);
      await tapCreate(tester);

      final semantics = find.ancestor(
        of: find.byKey(const ValueKey('consentError')),
        matching: find.byType(Semantics),
      );
      final widget = tester.widget<Semantics>(semantics.first);
      expect(widget.properties.liveRegion, isTrue);
    });

    testWidgets('a ticked box sends the consents the copy served', (tester) async {
      final client = FakeApiClient({
        ...standardRoutes(),
        'GET /v1/consent-copy': (_) => copy(),
        // 409 keeps the row on this screen: a success would navigate, and the bare test app has no router.
        'POST /v1/auth/register': (_) => const FakeHttpError(409, {'error': 'email_taken'}),
      });
      await pumpSignUp(tester, client);
      await fillForm(tester);
      await tester.tap(find.byType(Checkbox));
      await tester.pumpAndSettle();
      await tapCreate(tester);

      final sent = client.calls('POST', '/v1/auth/register');
      expect(sent, hasLength(1));
      expect(sent.single.body['consents'], {
        'termsPrivacy': true,
        'textVersion': 'signup-v1',
        'locale': 'en',
      });
    });

    testWidgets('a short password is named beside the fields and never sent', (tester) async {
      final client = await api();
      await pumpSignUp(tester, client);
      await fillForm(tester, password: 'ten-chars!');
      await tester.tap(find.byType(Checkbox));
      await tester.pumpAndSettle();
      await tapCreate(tester);

      expect(shown(tester, 'registerError'), en.registerPasswordTooShort);
      expect(client.calls('POST', '/v1/auth/register'), isEmpty);
    });

    testWidgets('a missing name is named before the request', (tester) async {
      final client = await api();
      await pumpSignUp(tester, client);
      await fillForm(tester, displayName: '   ');
      await tester.tap(find.byType(Checkbox));
      await tester.pumpAndSettle();
      await tapCreate(tester);

      expect(shown(tester, 'registerError'), en.registerNamesRequired);
      expect(client.calls('POST', '/v1/auth/register'), isEmpty);
    });

    testWidgets('an email without @ is named before the request', (tester) async {
      final client = await api();
      await pumpSignUp(tester, client);
      await fillForm(tester, email: 'sam.example.com');
      await tester.tap(find.byType(Checkbox));
      await tester.pumpAndSettle();
      await tapCreate(tester);

      expect(shown(tester, 'registerError'), en.authEmailInvalid);
      expect(client.calls('POST', '/v1/auth/register'), isEmpty);
    });

    testWidgets('a field the server rejects is named, never "Validation failed"', (tester) async {
      final client = FakeApiClient({
        ...withRegister((_) => const FakeHttpError(400, {
              'error': {
                'formErrors': <String>[],
                'fieldErrors': {
                  'email': ['Invalid email'],
                },
              },
            })),
        'GET /v1/consent-copy': (_) => copy(),
      });
      await pumpSignUp(tester, client);
      await fillForm(tester, email: 'sam@localhost');
      await tester.tap(find.byType(Checkbox));
      await tester.pumpAndSettle();
      await tapCreate(tester);

      expect(client.calls('POST', '/v1/auth/register'), hasLength(1));
      expect(shown(tester, 'registerError'), en.authEmailInvalid);
      expect(find.text('Validation failed'), findsNothing);
      expect(find.textContaining(kValidationFailedPrefix), findsNothing);
    });

    testWidgets('an outdated consent refetches and asks again, never showing the server code', (tester) async {
      final client = FakeApiClient({
        ...standardRoutes(),
        'GET /v1/consent-copy': (_) => copy(),
        'POST /v1/auth/register': (_) => const FakeHttpError(400, {'error': 'consent_text_outdated'}),
      });
      await pumpSignUp(tester, client);
      await fillForm(tester);
      await tester.tap(find.byType(Checkbox));
      await tester.pumpAndSettle();
      await tapCreate(tester);

      expect(find.textContaining('consent_text_outdated'), findsNothing);
      // The copy is read again so the new wording is on screen, and the box is unticked for the new text.
      expect(client.calls('GET', '/v1/consent-copy'), hasLength(2));
      final box = tester.widget<Checkbox>(find.byType(Checkbox));
      expect(box.value, isFalse);
      expect(shown(tester, 'consentError'), en.consentRequired);
    });

    testWidgets('a taken email says so', (tester) async {
      final client = FakeApiClient({
        ...withRegister((_) => const FakeHttpError(409, {'error': 'email_taken'})),
      });
      await pumpSignUp(tester, client);
      await fillForm(tester);
      await tester.tap(find.byType(Checkbox));
      await tester.pumpAndSettle();
      await tapCreate(tester);

      expect(shown(tester, 'registerError'), en.registerEmailTaken);
      expect(find.text('email_taken'), findsNothing);
    });

    testWidgets('Arabic: the consent error is the Bureau sentence, and the box text comes from the copy', (tester) async {
      final ar = lookupAppLocalizations(const Locale('ar'));
      // The Arabic Language Bureau's box 1 at the final English (6914704859-adjacent, doc 09 A1), verbatim.
      const arabicBox = 'أُقرّ بأنني بلغت سن الرشد، وبأنني أحد والدَي كل طفل أضيفه إلى تطبيق أسرة أو وصيّه القانوني أو شخص آخر مخوّل قانونًا برعايته. وأقبل [شروط استخدام تطبيق أسرة](https://osratech.com/ar/terms)، وقد قرأت [سياسة الخصوصية](https://osratech.com/ar/privacy).';
      final client = FakeApiClient({
        ...standardRoutes(),
        'GET /v1/consent-copy': (_) => copy(text: arabicBox),
        'POST /v1/auth/register': (_) => const FakeHttpError(409, {'error': 'email_taken'}),
      });
      await pumpSignUp(tester, client, locale: const Locale('ar'));
      await tester.enterText(fieldByLabel(ar.familyNameLabel), 'Rivera');
      await tester.enterText(fieldByLabel(ar.yourNameLabel), 'Sam');
      await tester.enterText(fieldByLabel(ar.emailLabel), 'new@osratech.com');
      await tester.enterText(fieldByLabel(ar.passwordLabel), validPassword);
      await tester.tap(find.byKey(const ValueKey('createAccountButton')));
      await tester.pumpAndSettle();

      expect(shown(tester, 'consentError'), ar.consentRequired);
      expect(shown(tester, 'consentTermsText'), contains('أُقرّ بأنني بلغت سن الرشد'));
      expect(find.text('شروط استخدام تطبيق أسرة'), findsOneWidget);

      // #862 condition 3: a multi-word Arabic label is shown with its spaces. The parser copies the
      // label out of the copy's markdown and rewrites nothing, so an underscore here would mean the
      // copy or a stub sent one — which is exactly what this pins.
      for (final key in ['consentTermsLink', 'consentPrivacyLink']) {
        for (final text in tester.widgetList<Text>(
          find.descendant(of: find.byKey(ValueKey(key)), matching: find.byType(Text)),
        )) {
          expect(text.data ?? '', isNot(contains('_')), reason: '$key renders "${text.data}"');
        }
      }
    });

    testWidgets('a copy the server cannot serve is a plain line, never a half form', (tester) async {
      final client = FakeApiClient({
        ...standardRoutes(),
        'GET /v1/consent-copy': (_) => const FakeHttpError(500),
      });
      await pumpSignUp(tester, client);
      expect(find.byType(Checkbox), findsNothing);
      expect(find.byKey(const ValueKey('createAccountButton')), findsNothing);
    });
  });

  group('field-error mapping', () {
    test('the provider keeps the rejected field names, sorted', () async {
      final api = FakeApiClient({
        'POST /v1/auth/register': (_) => const FakeHttpError(400, {
              'error': {
                'formErrors': <String>[],
                'fieldErrors': {
                  'password': ['too short'],
                  'email': ['Invalid email'],
                },
              },
            }),
      });
      final notifier = AuthNotifier(api);
      addTearDown(notifier.dispose);
      await notifier.register(
        email: 'x@y',
        password: 'p',
        displayName: 'a',
        familyName: 'b',
        region: 'US',
        consentTextVersion: 'signup-v1',
        consentLocale: 'en',
      );
      expect(notifier.state.error, '${kValidationFailedPrefix}email,password');
    });

    test('each field maps to its own sentence; anything else to the general one', () {
      expect(authFieldError(en, '${kValidationFailedPrefix}password'), en.registerPasswordTooShort);
      expect(authFieldError(en, '${kValidationFailedPrefix}familyName'), en.registerNamesRequired);
      expect(authFieldError(en, '${kValidationFailedPrefix}displayName'), en.registerNamesRequired);
      expect(authFieldError(en, '${kValidationFailedPrefix}email,password'), en.authEmailInvalid);
      expect(authFieldError(en, '${kValidationFailedPrefix}timezone'), en.authFieldsInvalid);
      expect(authFieldError(en, kValidationFailedPrefix), en.authFieldsInvalid);
    });
  });
}
