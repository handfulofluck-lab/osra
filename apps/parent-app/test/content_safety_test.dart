import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:familyshield_parent/api/models.dart';
import 'package:familyshield_parent/features/children/child_detail_screen.dart';
import 'package:familyshield_parent/features/content/search_safety_screen.dart';
import 'package:familyshield_parent/features/content/snippet_vault_modal.dart';
import 'package:familyshield_parent/features/rules/rules_editor_screen.dart';
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
              'concernTypes': ['drugs'],
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
      expect(find.text('drugs'), findsOneWidget);
      expect(find.text('violence'), findsOneWidget);
      expect(find.text('WARNING'), findsOneWidget);
      expect(find.text('CRITICAL'), findsOneWidget);
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
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
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
      expect(find.text('self_harm'), findsOneWidget);

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
