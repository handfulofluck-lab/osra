import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:familyshield_parent/core/ltr_isolate.dart';
import 'package:familyshield_parent/features/settings/digest_prefs_screen.dart';
import 'package:familyshield_parent/l10n/app_localizations.dart';
import 'package:familyshield_parent/providers/auth_provider.dart';
import 'package:familyshield_parent/providers/onboarding_provider.dart';
import 'package:familyshield_parent/widgets/field_question.dart';

import 'fake_api_client.dart';
import 'test_app.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final en = lookupAppLocalizations(const Locale('en'));

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({kOnboardingCompleteKey: true});
  });

  FakeApiClient prefsApi({List<String> initialEmails = const ['parent@example.com']}) {
    return FakeApiClient({
      'GET /v1/digests/prefs': (_) => {
            'dailyEmail': true,
            'weeklyEmail': false,
            'pushEnabled': true,
            'emails': initialEmails,
            'recipients': const [],
          },
      'PUT /v1/digests/prefs': (_) => {'ok': true},
      'GET /v1/family/me': (_) => {
            'family': {'id': 'fam-1', 'name': 'Demo', 'region': 'US', 'timezone': 'Asia/Dubai', 'children': []},
          },
    });
  }

  group('R-ID-10 digest email chips', () {
    testWidgets('adds, deduplicates, validates, removes chips and PUTs clean emails array', (tester) async {
      final api = prefsApi(initialEmails: ['parent@example.com', 'grandma@example.com']);
      await tester.pumpWidget(ProviderScope(
        overrides: [apiClientProvider.overrideWithValue(api)],
        child: localizedTestApp(const DigestPrefsScreen(), locale: const Locale('en')),
      ));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('digestEmailChip-parent@example.com')), findsOneWidget);
      expect(find.byKey(const ValueKey('digestEmailChip-grandma@example.com')), findsOneWidget);

      // Invalid address shows localized error and blocks save.
      await tester.enterText(find.byKey(const ValueKey('digestEmailAddInput')), 'not-an-email');
      await tester.tap(find.byKey(const ValueKey('digestEmailAddButton')));
      await tester.pumpAndSettle();
      expect(find.text(en.authEmailInvalid), findsOneWidget);

      await tester.scrollUntilVisible(find.text(en.digestPrefsSave), 150, scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text(en.digestPrefsSave));
      await tester.pumpAndSettle();
      expect(api.calls('PUT', '/v1/digests/prefs'), isEmpty);

      // Scroll back up to the input to replace invalid text with duplicate / valid email.
      await tester.scrollUntilVisible(find.byKey(const ValueKey('digestEmailAddInput')), -150, scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();

      // Valid duplicate (case-insensitive) clears input cleanly without duplicating chip.
      await tester.enterText(find.byKey(const ValueKey('digestEmailAddInput')), 'Grandma@Example.com');
      await tester.tap(find.byKey(const ValueKey('digestEmailAddButton')));
      await tester.pumpAndSettle();
      expect(find.text(en.authEmailInvalid), findsNothing);
      expect(find.byKey(const ValueKey('digestEmailChip-parent@example.com')), findsOneWidget);
      expect(find.byKey(const ValueKey('digestEmailChip-grandma@example.com')), findsOneWidget);

      // Remove one chip via its delete button.
      await tester.tap(find.byKey(const ValueKey('digestEmailRemove-grandma@example.com')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('digestEmailChip-grandma@example.com')), findsNothing);
      expect(find.byKey(const ValueKey('digestEmailChip-parent@example.com')), findsOneWidget);

      // Typing a valid email without tapping Add still commits on Save.
      await tester.enterText(find.byKey(const ValueKey('digestEmailAddInput')), 'uncle@example.com');
      await tester.scrollUntilVisible(find.text(en.digestPrefsSave), 150, scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text(en.digestPrefsSave));
      await tester.pumpAndSettle();

      final puts = api.calls('PUT', '/v1/digests/prefs');
      expect(puts, hasLength(1));
      expect(puts.single.body['emails'], ['parent@example.com', 'uncle@example.com']);

      await tester.scrollUntilVisible(find.byKey(const ValueKey('digestEmailChip-uncle@example.com')), -150, scrollable: find.byType(Scrollable).first);
      expect(find.byKey(const ValueKey('digestEmailChip-uncle@example.com')), findsOneWidget);

      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    });

    testWidgets('wraps full email chips and FieldQuestion at 320px width and 200% text scale in EN and AR', (tester) async {
      expect(
        ltrIsolateEmail('grandma@example.com'),
        '\u{2066}grandma@\u{200B}example.com\u{2069}',
      );

      for (final (locale, dir) in [(const Locale('en'), TextDirection.ltr), (const Locale('ar'), TextDirection.rtl)]) {
        final l10n = lookupAppLocalizations(locale);
        await tester.binding.setSurfaceSize(const Size(320, 568));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        final api = prefsApi(initialEmails: ['very.long.parent.address+family@subdomain.example.com']);
        await tester.pumpWidget(ProviderScope(
          overrides: [apiClientProvider.overrideWithValue(api)],
          child: MediaQuery(
            data: const MediaQueryData(size: Size(320, 568), textScaler: TextScaler.linear(2.0)),
            child: localizedTestApp(const DigestPrefsScreen(), locale: locale, textDirection: dir),
          ),
        ));
        await tester.pumpAndSettle();

        final chipFinder = find.byKey(const ValueKey('digestEmailChip-very.long.parent.address+family@subdomain.example.com'));
        await tester.scrollUntilVisible(chipFinder, 150, scrollable: find.byType(Scrollable).first);
        await tester.pumpAndSettle();
        expect(chipFinder, findsOneWidget);
        expect(find.byType(InputChip), findsNothing);
        final chipText = tester.widget<Text>(find.descendant(of: chipFinder, matching: find.byType(Text)));
        expect(chipText.data, ltrIsolateEmail('very.long.parent.address+family@subdomain.example.com'));
        expect(chipText.softWrap, isTrue);

        await tester.scrollUntilVisible(find.byKey(const ValueKey('digestEmailAddInput')), 150, scrollable: find.byType(Scrollable).first);
        await tester.pumpAndSettle();
        expect(find.byType(FieldQuestion), findsOneWidget);
        expect(find.descendant(of: find.byType(FieldQuestion), matching: find.text(l10n.familyEnterEmail)), findsOneWidget);
        final addField = tester.widget<TextField>(find.byKey(const ValueKey('digestEmailAddInput')));
        expect(addField.decoration?.labelText, isNull);
        expect(addField.decoration?.isDense, isNot(true));
        expect(tester.takeException(), isNull);
      }
    });
  });
}
