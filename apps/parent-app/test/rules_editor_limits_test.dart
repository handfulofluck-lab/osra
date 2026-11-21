import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:familyshield_parent/api/models.dart';
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

  Future<FakeApiClient> pumpWith(
    WidgetTester tester, {
    required int daily,
    required int weekend,
    bool legacyOverlap = false,
  }) async {
    final payload = ruleSetPayload('child-1');
    payload['screenTime'] = {
      ...Map<String, dynamic>.from(payload['screenTime'] as Map),
      'dailyLimitMinutes': daily,
      'weekendLimitMinutes': weekend,
      if (legacyOverlap) ...{
        'bedtimeStart': '14:00',
        'bedtimeEnd': '07:00',
        'schoolHours': {
          'start': '08:00',
          'end': '15:00',
          'days': [1, 2, 3, 4, 5],
        },
      },
    };
    final api = FakeApiClient({
      ...standardRoutes(),
      'GET /v1/rules/child-1': (_) => payload,
      if (legacyOverlap)
        'PUT /v1/rules/child-1': (_) =>
            const FakeHttpError(400, {'error': 'schedule_overlap'}),
      'PATCH /v1/rules/child-1': (req) => req.body.containsKey('screenTime')
          ? const FakeHttpError(400, {'error': 'schedule_overlap'})
          : {'ok': true},
    });
    await tester.pumpWidget(ProviderScope(
      overrides: [apiClientProvider.overrideWithValue(api)],
      child: localizedTestApp(const RulesEditorScreen(childId: 'child-1')),
    ));
    await tester.pumpAndSettle();
    return api;
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
      final patch = api.calls('PATCH', '/v1/rules/child-1').single.body;
      expect(patch.containsKey('screenTime'), isFalse);
    });
  }

  testWidgets('app edit saves without resubmitting a saved overlapping schedule', (tester) async {
    final api = await pumpWith(tester, daily: 120, weekend: 180, legacyOverlap: true);
    await tester.tap(find.text('Apps'));
    await tester.pumpAndSettle();

    final block = find.text('Block');
    final appList = find.descendant(
      of: find.byKey(const ValueKey('appsRulesList')),
      matching: find.byWidgetPredicate((widget) => widget is Scrollable && widget.axis == Axis.vertical),
    );
    await tester.scrollUntilVisible(block, 150, scrollable: appList);
    await tester.tap(block);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(api.calls('PUT', '/v1/rules/child-1'), isEmpty);
    final patch = api.calls('PATCH', '/v1/rules/child-1').single.body;
    expect(patch.keys, ['appRules']);
    expect((patch['appRules'] as List).single['action'], 'block');
    expect(find.text('Rules saved'), findsOneWidget);
  });

  test('an explicitly disabled school window retains its empty days', () {
    final screenTime = ScreenTimeRule.fromJson({
      'schoolHours': {'start': '08:00', 'end': '15:00', 'days': <int>[]},
    });
    expect(screenTime.schoolDays, isEmpty);
    expect((screenTime.toJson()['schoolHours'] as Map)['days'], isEmpty);
    expect(ScreenTimeRule.fromJson({}).schoolDays, [1, 2, 3, 4, 5]);
  });

  test('a changed school window remains intact in the patch', () {
    const beginning = RuleSet();
    final edited = beginning.copyWith(
      screenTime: const ScreenTimeRule(schoolStart: '09:00', schoolDays: [1, 3]),
    );
    expect(edited.changesFrom(beginning), {
      'screenTime': {
        'schoolHours': {'start': '09:00', 'end': '15:00', 'days': [1, 3]},
      },
    });
  });

  test('limitSliderPosition clamps only out-of-range values', () {
    expect(limitSliderPosition(1440), kLimitSliderMax);
    expect(limitSliderPosition(0), kLimitSliderMin);
    expect(limitSliderPosition(5), kLimitSliderMin);
    expect(limitSliderPosition(120), 120);
  });
}
