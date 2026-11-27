import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:familyshield_parent/api/models.dart';
import 'package:familyshield_parent/features/rules/rules_editor_screen.dart';
import 'package:familyshield_parent/providers/auth_provider.dart';

import 'fake_api_client.dart';
import 'test_app.dart';

/// #1172: Bedtime has an off switch, a new child starts with it off, and turning it on saves only that.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  test('B1 bedtimeEnabled parses, defaults to on, and round-trips', () {
    expect(ScreenTimeRule.fromJson(const {}).bedtimeEnabled, isTrue);
    expect(ScreenTimeRule.fromJson(const {'bedtimeEnabled': false}).bedtimeEnabled, isFalse);
    expect(const ScreenTimeRule(bedtimeEnabled: false).toJson()['bedtimeEnabled'], isFalse);
  });

  Map<String, dynamic> rules({required bool bedtimeOn}) {
    final r = ruleSetPayload('child-1');
    r['screenTime'] = {...(r['screenTime'] as Map<String, dynamic>), 'bedtimeEnabled': bedtimeOn};
    return r;
  }

  Future<FakeApiClient> pump(WidgetTester tester, {required bool bedtimeOn}) async {
    tester.view.physicalSize = const Size(1080, 6000);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final api = FakeApiClient({
      ...standardRoutes(),
      'GET /v1/rules/child-1': (_) => rules(bedtimeOn: bedtimeOn),
    });
    await tester.pumpWidget(ProviderScope(
      overrides: [apiClientProvider.overrideWithValue(api)],
      child: localizedTestApp(const RulesEditorScreen(childId: 'child-1')),
    ));
    await tester.pumpAndSettle();
    return api;
  }

  testWidgets('B2 Bedtime off hides its times; turning it on shows them and saves only the switch', (tester) async {
    final api = await pump(tester, bedtimeOn: false);

    final sw = find.byKey(const ValueKey('bedtimeEnabledSwitch'));
    expect(sw, findsOneWidget);
    expect(tester.widget<SwitchListTile>(sw).value, isFalse);
    expect(find.textContaining('21:00'), findsNothing);

    await tester.tap(sw);
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(sw).value, isTrue);
    expect(find.textContaining('21:00'), findsOneWidget);

    await tester.tap(find.text('Save').first);
    await tester.pumpAndSettle();
    final patch = api.calls('PATCH', '/v1/rules/child-1');
    expect(patch, hasLength(1));
    expect(patch.single.data, {
      'screenTime': {'bedtimeEnabled': true},
    });
  });

  testWidgets('B3 an existing child with Bedtime on keeps its times visible', (tester) async {
    await pump(tester, bedtimeOn: true);

    expect(tester.widget<SwitchListTile>(find.byKey(const ValueKey('bedtimeEnabledSwitch'))).value, isTrue);
    expect(find.textContaining('21:00'), findsOneWidget);
  });
}
