import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:familyshield_parent/core/localized_list.dart';
import 'package:familyshield_parent/features/rules/rules_editor_screen.dart';
import 'package:familyshield_parent/features/settings/digest_prefs_screen.dart';
import 'package:familyshield_parent/l10n/app_localizations.dart';
import 'package:familyshield_parent/providers/auth_provider.dart';

import 'fake_api_client.dart';
import 'test_app.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  group('splitLocalizedList', () {
    test('splits mixed comma families and removes empty items', () {
      expect(splitLocalizedList('a.com, b.com،c.com,،'), ['a.com', 'b.com', 'c.com']);
    });

    test('splits semicolon families and line breaks, then trims', () {
      expect(splitLocalizedList(' a؛b\nc, d\r\n'), ['a', 'b', 'c', 'd']);
    });

    test('removes direction marks only when requested', () {
      expect(
        splitLocalizedList('\u200E\u200Fa.com\u061C', stripDirectionMarks: true),
        ['a.com'],
      );
      expect(splitLocalizedList('\u200Fqa@osratech.com'), ['\u200Fqa@osratech.com']);
    });
  });

  group('localized list fields', () {
    final arabic = lookupAppLocalizations(const Locale('ar'));

    Future<void> flushFakeHttp(WidgetTester tester) async {
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.pumpAndSettle();
    }

    Finder fieldByLabel(String label) =>
        find.ancestor(of: find.text(label), matching: find.byType(TextField));

    Future<void> pumpScreen(WidgetTester tester, Widget home, FakeApiClient api) async {
      await tester.pumpWidget(ProviderScope(
        overrides: [apiClientProvider.overrideWithValue(api)],
        child: localizedTestApp(
          home,
          locale: const Locale('ar'),
          textDirection: TextDirection.rtl,
        ),
      ));
      await tester.pumpAndSettle();
    }

    Future<void> saveWebFilterDomains(
      WidgetTester tester,
      FakeApiClient api, {
      required String label,
      required String field,
      required String input,
      required List<String> expected,
    }) async {
      final textField = fieldByLabel(label);
      await tester.scrollUntilVisible(
        textField,
        150,
        scrollable: find.descendant(
          of: find.byKey(const ValueKey('webFilterList')),
          matching: find.byWidgetPredicate((widget) => widget is Scrollable && widget.axis == Axis.vertical),
        ),
      );
      await tester.enterText(textField, input);
      await tester.tap(find.text(arabic.save));
      await flushFakeHttp(tester);

      final puts = api.calls('PUT', '/v1/rules/child-1');
      expect(puts, isNotEmpty);
      expect(puts.last.body['webFilter'][field], expected);
    }

    Future<void> openWebFilter(WidgetTester tester, FakeApiClient api) async {
      await pumpScreen(tester, const RulesEditorScreen(childId: 'child-1'), api);
      await tester.tap(find.text(arabic.tabWebFilter));
      await tester.pumpAndSettle();
    }

    testWidgets('allowed domains save Arabic and Latin comma-separated items', (tester) async {
      final api = FakeApiClient(standardRoutes());
      await openWebFilter(tester, api);

      await saveWebFilterDomains(
        tester,
        api,
        label: arabic.allowedDomainsLabel,
        field: 'allowedDomains',
        input: 'a.com، b.com',
        expected: ['a.com', 'b.com'],
      );
      await saveWebFilterDomains(
        tester,
        api,
        label: arabic.allowedDomainsLabel,
        field: 'allowedDomains',
        input: 'a.com, b.com،c.com',
        expected: ['a.com', 'b.com', 'c.com'],
      );
    });

    testWidgets('blocked domains save Arabic and Latin comma-separated items', (tester) async {
      final api = FakeApiClient(standardRoutes());
      await openWebFilter(tester, api);

      await saveWebFilterDomains(
        tester,
        api,
        label: arabic.blockedDomainsLabel,
        field: 'blockedDomains',
        input: 'a.com، b.com',
        expected: ['a.com', 'b.com'],
      );
      await saveWebFilterDomains(
        tester,
        api,
        label: arabic.blockedDomainsLabel,
        field: 'blockedDomains',
        input: 'a.com, b.com،c.com',
        expected: ['a.com', 'b.com', 'c.com'],
      );
    });

    testWidgets('blocked domains drop a leading direction mark before saving', (tester) async {
      final api = FakeApiClient(standardRoutes());
      await openWebFilter(tester, api);

      await saveWebFilterDomains(
        tester,
        api,
        label: arabic.blockedDomainsLabel,
        field: 'blockedDomains',
        input: '\u200Fa.com',
        expected: ['a.com'],
      );
    });

    Future<void> saveRoutineApps(
      WidgetTester tester,
      FakeApiClient api, {
      required String label,
      required String field,
      required String input,
      required List<String> expected,
    }) async {
      await tester.ensureVisible(find.text(arabic.addRoutine));
      await tester.pumpAndSettle();
      await tester.tap(find.text(arabic.addRoutine));
      await tester.pumpAndSettle();

      final dialog = find.byType(AlertDialog);
      await tester.enterText(
        find.descendant(of: dialog, matching: fieldByLabel(arabic.nameLabel)),
        'Localized list',
      );
      await tester.enterText(find.descendant(of: dialog, matching: fieldByLabel(label)), input);
      await tester.tap(find.descendant(of: dialog, matching: find.text(arabic.save)));
      await tester.pumpAndSettle();
      await tester.tap(find.text(arabic.save));
      await flushFakeHttp(tester);

      final puts = api.calls('PUT', '/v1/rules/child-1');
      expect(puts, isNotEmpty);
      expect(puts.last.body['routines'].last[field], expected);
    }

    Future<void> openRoutines(WidgetTester tester, FakeApiClient api) async {
      await pumpScreen(tester, const RulesEditorScreen(childId: 'child-1'), api);
      await tester.tap(find.text(arabic.tabRoutines));
      await tester.pumpAndSettle();
    }

    testWidgets('routine blocked apps save Arabic and Latin comma-separated items', (tester) async {
      final api = FakeApiClient(standardRoutes());
      await openRoutines(tester, api);

      await saveRoutineApps(
        tester,
        api,
        label: arabic.blockedAppsLabel,
        field: 'blockedApps',
        input: 'a.com، b.com',
        expected: ['a.com', 'b.com'],
      );
      await saveRoutineApps(
        tester,
        api,
        label: arabic.blockedAppsLabel,
        field: 'blockedApps',
        input: 'a.com, b.com،c.com',
        expected: ['a.com', 'b.com', 'c.com'],
      );
    });

    testWidgets('routine allowed apps save Arabic and Latin comma-separated items', (tester) async {
      final api = FakeApiClient(standardRoutes());
      await openRoutines(tester, api);

      await saveRoutineApps(
        tester,
        api,
        label: arabic.allowedAppsLabel,
        field: 'allowedApps',
        input: 'a.com، b.com',
        expected: ['a.com', 'b.com'],
      );
      await saveRoutineApps(
        tester,
        api,
        label: arabic.allowedAppsLabel,
        field: 'allowedApps',
        input: 'a.com, b.com،c.com',
        expected: ['a.com', 'b.com', 'c.com'],
      );
    });

    Future<void> saveDigestEmails(
      WidgetTester tester,
      FakeApiClient api,
      String input,
      List<String> expected,
    ) async {
      await tester.enterText(fieldByLabel(arabic.digestPrefsEmailsLabel), input);
      await tester.ensureVisible(find.text(arabic.digestPrefsSave));
      await tester.pumpAndSettle();
      await tester.tap(find.text(arabic.digestPrefsSave));
      await flushFakeHttp(tester);

      final puts = api.calls('PUT', '/v1/digests/prefs');
      expect(puts, isNotEmpty);
      expect(puts.last.body['emails'], expected);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    }

    testWidgets('digest recipients save Arabic and Latin comma-separated items', (tester) async {
      final api = FakeApiClient({
        ...standardRoutes(),
        'GET /v1/digests/prefs': (_) => {
              'dailyEmail': true,
              'weeklyEmail': false,
              'pushEnabled': true,
              'emails': ['qa@osratech.com'],
              'recipients': const [],
            },
        'PUT /v1/digests/prefs': (_) => {'ok': true},
      });
      await pumpScreen(tester, const DigestPrefsScreen(), api);

      await saveDigestEmails(tester, api, 'a.com، b.com', ['a.com', 'b.com']);
      await saveDigestEmails(tester, api, 'a.com, b.com،c.com', ['a.com', 'b.com', 'c.com']);
    });
  });
}
