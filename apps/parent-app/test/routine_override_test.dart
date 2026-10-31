import 'package:familyshield_parent/api/models.dart';
import 'package:familyshield_parent/features/children/child_detail_screen.dart';
import 'package:familyshield_parent/features/rules/active_window.dart';
import 'package:familyshield_parent/providers/auth_provider.dart';
import 'package:familyshield_parent/providers/clock_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_api_client.dart';
import 'test_app.dart';

/// Issue #456: a parent's app list must say which window is holding an app shut, and must not invent
/// one the child agent would not apply.
///
/// The ordering these rows pin is the agent's (`RuleEngine.evaluate`), not a convenience: routines are
/// read before per-app rules, and an explicit `allow` returns ALLOW before bedtime or school hours.
/// Mutant for the widget rows: drop `AppRule.action == 'allow'` from the short-circuit in
/// `activeWindowFor` and `allow_is_not_overridden_by_school_hours` goes red with a "School hours"
/// sentence on an app the phone would open.
void main() {
  RuleSet rules({
    List<AppRule> appRules = const [],
    List<Routine> routines = const [],
    List<String> alwaysAllowed = const [],
    List<int> schoolDays = const [1, 2, 3, 4, 5],
  }) =>
      RuleSet(
        id: 'rules-1',
        childId: 'child-1',
        screenTime: ScreenTimeRule(schoolDays: schoolDays),
        webFilter: const WebFilterRule(),
        appRules: appRules,
        routines: routines,
        alwaysAllowedApps: alwaysAllowed,
        updatedAt: null,
      );

  // 2026-11-02 is a Monday, so `DateTime.weekday == 1` and the five school days apply.
  DateTime monday(int hour, int minute) => DateTime(2026, 11, 2, hour, minute);

  group('activeWindowFor mirrors the agent order', () {
    test('school hours hold an app that has no rule of its own', () {
      final w = activeWindowFor(packageId: 'com.example.meet', rules: rules(), now: monday(10, 0));
      expect(w, const ActiveWindow(kind: WindowKind.school, endsAt: '15:00'));
    });

    test('school hours release the app outside the window', () {
      expect(activeWindowFor(packageId: 'com.example.meet', rules: rules(), now: monday(16, 30)), isNull);
    });

    test('school hours do not apply on a day the rule excludes', () {
      // Saturday 10:00: the default school days are Mon–Fri.
      expect(
        activeWindowFor(packageId: 'com.example.meet', rules: rules(), now: DateTime(2026, 11, 7, 10, 0)),
        isNull,
      );
    });

    test('bedtime holds an app that has no rule of its own', () {
      final w = activeWindowFor(packageId: 'com.example.meet', rules: rules(), now: monday(22, 0));
      expect(w, const ActiveWindow(kind: WindowKind.bedtime, endsAt: '07:00'));
    });

    test('an explicit allow is not overridden by school hours (RuleEngine.kt:66)', () {
      final w = activeWindowFor(
        packageId: 'com.example.meet',
        rules: rules(appRules: const [AppRule(packageId: 'com.example.meet', appName: 'Meet')]),
        now: monday(10, 0),
      );
      expect(w, isNull, reason: 'the agent returns ALLOW before the school-hours window is read');
    });

    test('an explicit block is the rule itself, not a window', () {
      final w = activeWindowFor(
        packageId: 'com.example.game',
        rules: rules(appRules: const [AppRule(packageId: 'com.example.game', appName: 'Game', action: 'block')]),
        now: monday(10, 0),
      );
      expect(w, isNull);
    });

    test('a routine overrides an allowed app, because routines are read first', () {
      final w = activeWindowFor(
        packageId: 'com.example.meet',
        rules: rules(
          appRules: const [AppRule(packageId: 'com.example.meet', appName: 'Meet')],
          routines: const [
            Routine(
              id: 'r1',
              name: 'Homework',
              startTime: '17:00',
              endTime: '19:00',
              days: [1, 2, 3],
              blockedApps: ['com.example.meet'],
            ),
          ],
        ),
        now: monday(17, 30),
      );
      expect(w, const ActiveWindow(kind: WindowKind.routine, routineName: 'Homework', endsAt: '19:00'));
    });

    test('a routine block on an app the parent also blocked gets no sentence (#474 review)', () {
      // The row already says "Blocked"; naming Homework would promise it opens at 19:00, and it does not.
      final w = activeWindowFor(
        packageId: 'com.example.game',
        rules: rules(
          appRules: const [AppRule(packageId: 'com.example.game', appName: 'Game', action: 'block')],
          routines: const [
            Routine(
              id: 'r1',
              name: 'Homework',
              startTime: '17:00',
              endTime: '19:00',
              days: [1, 2, 3],
              blockedApps: ['com.example.game'],
            ),
          ],
        ),
        now: monday(17, 30),
      );
      expect(w, isNull);
    });

    test('a routine only applies on its own days (#474 F2)', () {
      // Thursday 17:30: Homework is Mon–Wed, so nothing holds the app.
      final w = activeWindowFor(
        packageId: 'com.example.meet',
        rules: rules(
          routines: const [
            Routine(
              id: 'r1',
              name: 'Homework',
              startTime: '17:00',
              endTime: '19:00',
              days: [1, 2, 3],
              blockedApps: ['com.example.meet'],
            ),
          ],
        ),
        now: DateTime(2026, 11, 5, 17, 30),
      );
      expect(w, isNull);
    });

    test('the start of a routine is inside it (#474 F3)', () {
      final w = activeWindowFor(
        packageId: 'com.example.meet',
        rules: rules(
          routines: const [
            Routine(
              id: 'r1',
              name: 'Homework',
              startTime: '17:00',
              endTime: '19:00',
              days: [1],
              blockedApps: ['com.example.meet'],
            ),
          ],
        ),
        now: monday(17, 0),
      );
      expect(w?.routineName, 'Homework');
    });

    test('the end of a routine is outside it, so it never says "until 19:00" at 19:00 (#474 F1)', () {
      final w = activeWindowFor(
        packageId: 'com.example.meet',
        rules: rules(
          routines: const [
            Routine(
              id: 'r1',
              name: 'Homework',
              startTime: '17:00',
              endTime: '19:00',
              days: [1],
              blockedApps: ['com.example.meet'],
            ),
          ],
        ),
        now: monday(19, 0),
      );
      expect(w, isNull);
    });

    test('a routine allow-list blocks every app it does not name', () {
      final w = activeWindowFor(
        packageId: 'com.example.meet',
        rules: rules(
          routines: const [
            Routine(
              id: 'r1',
              name: 'Study',
              startTime: '16:00',
              endTime: '18:00',
              days: [1],
              allowedApps: ['com.example.dictionary'],
            ),
          ],
        ),
        now: monday(16, 30),
      );
      expect(w?.routineName, 'Study');
    });

    test('a routine allow-list leaves its own allowed apps alone', () {
      final w = activeWindowFor(
        packageId: 'com.example.dictionary',
        rules: rules(
          routines: const [
            Routine(
              id: 'r1',
              name: 'Study',
              startTime: '16:00',
              endTime: '18:00',
              days: [1],
              allowedApps: ['com.example.dictionary'],
            ),
          ],
        ),
        now: monday(16, 30),
      );
      expect(w, isNull);
    });

    test('an always-allowed app is never held by a window', () {
      final w = activeWindowFor(
        packageId: 'com.example.dialer',
        rules: rules(alwaysAllowed: const ['com.example.dialer']),
        now: monday(22, 0),
      );
      expect(w, isNull);
    });

    test('an overnight window is still in force after midnight', () {
      // Date(2026, 11, 3) is a Tuesday; bedtime 21:00–07:00 wraps.
      final w = activeWindowFor(packageId: 'com.example.meet', rules: rules(), now: DateTime(2026, 11, 3, 2, 0));
      expect(w, const ActiveWindow(kind: WindowKind.bedtime, endsAt: '07:00'));
    });

    test('equal start and end is an empty window, as in the agent', () {
      final base = rules();
      final r = RuleSet(
        id: base.id,
        childId: base.childId,
        screenTime: const ScreenTimeRule(bedtimeStart: '07:00', bedtimeEnd: '07:00'),
        webFilter: base.webFilter,
        appRules: base.appRules,
        routines: base.routines,
        updatedAt: null,
      );
      expect(activeWindowFor(packageId: 'com.example.meet', rules: r, now: monday(7, 0)), isNull);
    });
  });

  group('the app row says which window is holding it shut', () {
    Map<String, dynamic> payload() => {
          ...ruleSetPayload('child-1'),
          'screenTime': {
            'dailyLimitMinutes': 120,
            'weekendLimitMinutes': 240,
            'bedtimeStart': '21:00',
            'bedtimeEnd': '07:00',
            'schoolHours': {'start': '08:00', 'end': '15:00', 'days': [1, 2, 3, 4, 5]},
          },
          'appRules': [
            {'packageId': 'com.example.meet', 'appName': 'Meet', 'action': 'allow'},
            {'packageId': 'com.example.game', 'appName': 'Game', 'action': 'time_limit', 'dailyLimitMinutes': 60},
          ],
          'routines': [
            {
              'id': 'r1',
              'name': 'Homework',
              'startTime': '17:00',
              'endTime': '19:00',
              'days': [1, 2, 3],
              'blockedApps': ['com.example.meet'],
              'allowedApps': <String>[],
            },
          ],
        };

    Future<void> pumpApps(WidgetTester tester, DateTime now) async {
      final api = FakeApiClient({
        ...standardRoutes(),
        'GET /v1/rules/child-1': (_) => payload(),
      });
      await tester.pumpWidget(ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(api),
          clockProvider.overrideWithValue(() => now),
        ],
        child: localizedTestApp(const ChildDetailScreen(childId: 'child-1')),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Apps'));
      await tester.pumpAndSettle();
    }

    testWidgets('a routine overriding an allowed app is named with its end time', (tester) async {
      await pumpApps(tester, monday(17, 30));
      expect(find.text('Blocked now by Homework (until 19:00)'), findsOneWidget);
      // The app whose own rule is a time limit carries no window sentence: a wrong reason is worse
      // than none.
      expect(find.textContaining('Blocked now by'), findsOneWidget);
    });

    testWidgets('nothing is claimed once the routine ends', (tester) async {
      await pumpApps(tester, monday(19, 30));
      expect(find.textContaining('Blocked now by'), findsNothing);
    });

    testWidgets('an allowed app is not described as blocked by school hours', (tester) async {
      await pumpApps(tester, monday(10, 0));
      expect(find.textContaining('Blocked now by'), findsNothing);
    });
  });
  /// #476: the child's phone enforces a routine in the family's zone, so the sentence is read there.
  /// Each row derives the family offset from the test machine's own offset, so it holds in any zone CI
  /// runs in. Mutants: ignore the offset → the "four hours behind" row shows a sentence; apply it with
  /// the wrong sign → the "an hour ahead" row loses its sentence; drop the field on the server → the
  /// API row in `timezone.test.ts`.
  group('the routine sentence is read on the family clock (#476)', () {
    test('familyWallClock shifts the instant by the family offset, and keeps the clock without one', () {
      final instant = DateTime.utc(2026, 11, 2, 12, 30);
      final dubai = familyWallClock(instant, 240);
      expect([dubai.weekday, dubai.hour, dubai.minute], [1, 16, 30]);
      final newYork = familyWallClock(instant, -300);
      expect([newYork.hour, newYork.minute], [7, 30]);
      expect(familyWallClock(instant, null), instant);
    });

    Map<String, dynamic> payload() => {
          ...ruleSetPayload('child-1'),
          'appRules': [
            {'packageId': 'com.example.meet', 'appName': 'Meet', 'action': 'allow'},
          ],
          'routines': [
            {
              'id': 'r1',
              'name': 'Homework',
              'startTime': '17:00',
              'endTime': '19:00',
              'days': [1, 2, 3],
              'blockedApps': ['com.example.meet'],
              'allowedApps': <String>[],
            },
          ],
        };

    Future<void> pumpApps(WidgetTester tester, DateTime parentClock, int? familyOffset) async {
      final me = familyMeTwoChildren();
      if (familyOffset != null) {
        me['family'] = {...Map<String, dynamic>.from(me['family'] as Map), 'utcOffsetMinutes': familyOffset};
      }
      final api = FakeApiClient({
        ...standardRoutes(familyMe: me),
        'GET /v1/rules/child-1': (_) => payload(),
      });
      await tester.pumpWidget(ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(api),
          clockProvider.overrideWithValue(() => parentClock),
        ],
        child: localizedTestApp(const ChildDetailScreen(childId: 'child-1')),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Apps'));
      await tester.pumpAndSettle();
    }

    testWidgets('a parent four hours ahead of the family is not in the window at 17:30 parent time', (tester) async {
      final parent = monday(17, 30);
      await pumpApps(tester, parent, parent.timeZoneOffset.inMinutes - 240);
      // 13:30 on the family clock: Homework (17:00–19:00) has not started on the child's phone.
      expect(find.textContaining('Blocked now by'), findsNothing);
    });

    testWidgets('with the family an hour ahead, 16:30 parent time is 17:30 there and in the window', (tester) async {
      final parent = monday(16, 30);
      await pumpApps(tester, parent, parent.timeZoneOffset.inMinutes + 60);
      expect(find.text('Blocked now by Homework (until 19:00)'), findsOneWidget);
    });

    testWidgets('with no family zone set, the parent clock is used', (tester) async {
      await pumpApps(tester, monday(17, 30), null);
      expect(find.text('Blocked now by Homework (until 19:00)'), findsOneWidget);
    });
  });
}
