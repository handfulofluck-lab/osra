import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:familyshield_parent/features/rules/rules_editor_screen.dart';
import 'package:familyshield_parent/providers/auth_provider.dart';

import 'fake_api_client.dart';
import 'test_app.dart';

/// Issue #505 (Flip4): a child with 1440 minutes stored crashed the Edit rules screen, because `Slider`
/// throws for a value outside `[15, 600]`. The thumb is clamped; the stored value is shown and kept.
///
/// Mutants: drop the clamp in `limitSliderPosition` → every out-of-range row throws; save the clamped
/// value instead of the stored one → the "saving without touching the slider" checks go red.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  Future<FakeApiClient> pumpWith(WidgetTester tester, {required int daily, required int weekend}) async {
    final payload = ruleSetPayload('child-1');
    payload['screenTime'] = {
      ...Map<String, dynamic>.from(payload['screenTime'] as Map),
      'dailyLimitMinutes': daily,
      'weekendLimitMinutes': weekend,
    };
    final api = FakeApiClient({
      ...standardRoutes(),
      'GET /v1/rules/child-1': (_) => payload,
      'PUT /v1/rules/child-1': (_) => {'ok': true},
    });
    await tester.pumpWidget(ProviderScope(
      overrides: [apiClientProvider.overrideWithValue(api)],
      child: localizedTestApp(const RulesEditorScreen(childId: 'child-1')),
    ));
    await tester.pumpAndSettle();
    return api;
  }

  Map<String, dynamic> savedScreenTime(FakeApiClient api) {
    final put = api.requests.lastWhere((r) => r.method == 'PUT' && r.path == '/v1/rules/child-1');
    return Map<String, dynamic>.from((put.data as Map)['screenTime'] as Map);
  }

  for (final (daily, weekend) in [(1440, 1440), (0, 0), (5, 900)]) {
    testWidgets('the editor opens with $daily / $weekend stored, shows them, and saves them unchanged', (tester) async {
      final api = await pumpWith(tester, daily: daily, weekend: weekend);
      expect(tester.takeException(), isNull, reason: 'the slider must not be handed an out-of-range value');
      expect(find.text('Daily limit: $daily min'), findsOneWidget);
      expect(find.text('Weekend limit: $weekend min'), findsOneWidget);

      final sliders = tester.widgetList<Slider>(find.byType(Slider)).toList();
      expect(sliders, hasLength(2));
      for (final s in sliders) {
        expect(s.value, inInclusiveRange(s.min, s.max));
      }

      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      final saved = savedScreenTime(api);
      expect(saved['dailyLimitMinutes'], daily, reason: 'saving another rule must not rewrite the limit');
      expect(saved['weekendLimitMinutes'], weekend);
    });
  }

  test('limitSliderPosition clamps only out-of-range values', () {
    expect(limitSliderPosition(1440), kLimitSliderMax);
    expect(limitSliderPosition(0), kLimitSliderMin);
    expect(limitSliderPosition(5), kLimitSliderMin);
    expect(limitSliderPosition(120), 120);
  });
}
