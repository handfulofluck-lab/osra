import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:familyshield_parent/features/rules/rules_editor_screen.dart';
import 'package:familyshield_parent/providers/auth_provider.dart';

import 'fake_api_client.dart';
import 'test_app.dart';

/// ADR-0037 decision 3: on an iPhone a blocked app id is hidden, not shown with the OSRA screen. The rules
/// editor says so under each blocked app rule, and only when the child has an iPhone.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  Future<void> pumpApps(WidgetTester tester, {required String platform}) async {
    final family = familyMeTwoChildren();
    family['devices'] = [
      for (final d in family['devices'] as List)
        if ((d as Map)['childId'] == 'child-1') {...d, 'platform': platform} else d,
    ];
    final rules = ruleSetPayload('child-1');
    rules['appRules'] = [
      {'packageId': 'com.example.game', 'appName': 'Game', 'action': 'block'},
      {'packageId': 'com.example.reader', 'appName': 'Reader', 'action': 'allow'},
    ];
    final api = FakeApiClient({
      ...standardRoutes(familyMe: family),
      'GET /v1/rules/child-1': (_) => rules,
    });
    await tester.pumpWidget(ProviderScope(
      overrides: [apiClientProvider.overrideWithValue(api)],
      child: localizedTestApp(const RulesEditorScreen(childId: 'child-1')),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Apps'));
    await tester.pumpAndSettle();
  }

  testWidgets('a blocked app rule says it is hidden on the iPhone', (tester) async {
    await pumpApps(tester, platform: 'ios');
    expect(find.byKey(const ValueKey('hiddenOnIphone-com.example.game')), findsOneWidget);
    expect(find.text('On the iPhone, this app is hidden instead of showing the OSRA screen.'), findsOneWidget);
    expect(find.byKey(const ValueKey('hiddenOnIphone-com.example.reader')), findsNothing, reason: 'allow rules say nothing');
  });

  testWidgets('a child with no iPhone sees no such line', (tester) async {
    await pumpApps(tester, platform: 'android');
    expect(find.byKey(const ValueKey('hiddenOnIphone-com.example.game')), findsNothing);
  });
}
