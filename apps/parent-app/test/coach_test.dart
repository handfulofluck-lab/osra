import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:familyshield_parent/features/alerts/alerts_screen.dart';
import 'package:familyshield_parent/features/coach/coach_card_section.dart';
import 'package:familyshield_parent/features/coach/coach_content.dart';
import 'package:familyshield_parent/features/social/social_screen.dart';
import 'package:familyshield_parent/providers/auth_provider.dart';

import 'fake_api_client.dart';
import 'test_app.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  Future<void> pumpApp(WidgetTester tester, Widget home, FakeApiClient api) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [apiClientProvider.overrideWithValue(api)],
      child: localizedTestApp(home),
    ));
    await tester.pumpAndSettle();
  }

  /// Lets the fake-Dio zero-duration timer chains complete.
  Future<void> flushFakeHttp(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  /// Expands the coach section inside whatever widget tree is currently shown.
  Future<void> expandCoachSection(WidgetTester tester) async {
    await tester.tap(find.text('How to talk about this'));
    await tester.pumpAndSettle();
  }

  group('coachCardFor content DB', () {
    const mappedCategories = [
      'self_harm',
      'grooming',
      'cyberbullying',
      'sexual_content',
      'violence',
      'hate_speech',
      'social_concern',
      'screen_time_exceeded',
      'screen_time',
      'gaming_chat',
    ];

    test('every mapped category returns non-empty EN+AR title, body and tips', () {
      for (final cat in mappedCategories) {
        final card = coachCardFor(cat);
        expect(card.title, isNotEmpty, reason: '$cat title');
        expect(card.titleAr, isNotEmpty, reason: '$cat titleAr');
        expect(card.body, isNotEmpty, reason: '$cat body');
        expect(card.bodyAr, isNotEmpty, reason: '$cat bodyAr');
        expect(card.tips, isNotEmpty, reason: '$cat tips');
        expect(card.tipsAr, hasLength(card.tips.length), reason: '$cat tipsAr');
        for (var i = 0; i < card.tips.length; i++) {
          expect(card.tips[i], isNotEmpty, reason: '$cat tip $i');
          expect(card.tipsAr[i], isNotEmpty, reason: '$cat tipAr $i');
        }
      }
    });

    test('unknown categories fall back to the generic card', () {
      final card = coachCardFor('totally_new_category');
      expect(card.title, coachCardFor('another_unknown').title);
      expect(card.title, 'A calm first conversation');
    });

    test('social_concern resolves through concernTypes before falling back', () {
      expect(coachCardFor('social_concern', const ['grooming_risk']).title, contains('grooming'));
      expect(coachCardFor('social_concern', const ['self_harm']).title, contains('hurting'));
      expect(
        coachCardFor('social_concern', const ['late_night', 'grooming']).title,
        contains('grooming'),
      );
      expect(coachCardFor('social_concern', const ['late_night']).title, coachCardFor('social_concern').title);
    });

    test('screen_time alerts get the collaboration card', () {
      expect(coachCardFor('screen_time').title, contains('screen-time'));
      expect(coachCardFor('screen_time_exceeded').title, coachCardFor('screen_time').title);
    });
  });

  group('CoachCardSection widget', () {
    testWidgets('shows EN body by default and switches to AR on toggle', (tester) async {
      final card = coachCardFor('self_harm');
      await tester.pumpWidget(localizedTestApp(Scaffold(body: CoachCardSection(card: card))));
      await expandCoachSection(tester);

      expect(find.textContaining('Take every sign seriously'), findsOneWidget);
      expect(find.text('عربي'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('coachLangToggle')));
      await tester.pumpAndSettle();

      expect(find.textContaining('Take every sign seriously'), findsNothing);
      expect(find.textContaining('خذ كل مؤشر'), findsOneWidget);
      expect(find.text(card.tipsAr.first), findsOneWidget);
      expect(find.text('EN'), findsOneWidget);
    });
  });

  group('AlertsScreen coach integration', () {
    Future<void> openDetail(WidgetTester tester, FakeApiClient api, String alertTitle) async {
      await pumpApp(tester, const AlertsScreen(), api);
      await flushFakeHttp(tester);
      await tester.tap(find.text(alertTitle));
      await tester.pumpAndSettle();
    }

    testWidgets('a self_harm alert shows the coach section with crisis-first guidance', (tester) async {
      final now = DateTime.now();
      final api = FakeApiClient(standardRoutes(alerts: [
        alertJson('c1', 'critical', 'self_harm', 'Possible self-harm detected', now),
      ]));
      await openDetail(tester, api, 'Alert');

      expect(find.text('How to talk about this'), findsOneWidget);
      await expandCoachSection(tester);
      final card = coachCardFor('self_harm');
      expect(find.textContaining('Take every sign seriously'), findsOneWidget);
      expect(find.text(card.tips.first), findsOneWidget);
      expect(find.text(card.tips.last), findsOneWidget);
    });

    testWidgets('language toggle switches the dialog coach card to Arabic', (tester) async {
      final now = DateTime.now();
      final api = FakeApiClient(standardRoutes(alerts: [
        alertJson('c1', 'critical', 'self_harm', 'Possible self-harm detected', now),
      ]));
      await openDetail(tester, api, 'Alert');
      await expandCoachSection(tester);

      // The expanded card is taller than the dialog viewport — scroll the
      // dialog content until the toggle is hittable.
      final dialogScrollable = find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byWidgetPredicate((w) => w is Scrollable && w.axis == Axis.vertical),
      );
      await tester.scrollUntilVisible(find.byKey(const ValueKey('coachLangToggle')), 120,
          scrollable: dialogScrollable);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('coachLangToggle')));
      await tester.pumpAndSettle();

      expect(find.textContaining('خذ كل مؤشر'), findsOneWidget);
      expect(find.text('كيف تتحدث مع طفلك عن هذا'), findsOneWidget);
    });

    testWidgets('a screen_time alert shows the collaboration card', (tester) async {
      final now = DateTime.now();
      final api = FakeApiClient(standardRoutes(alerts: [
        alertJson('c1', 'info', 'screen_time', 'Daily limit reached', now),
      ]));
      await openDetail(tester, api, 'Daily limit reached');
      await expandCoachSection(tester);

      expect(find.text('Agreeing on screen-time limits together'), findsOneWidget);
      expect(find.textContaining('collaboration, not punishment'), findsOneWidget);
    });

    testWidgets('an unknown category shows the generic card', (tester) async {
      final now = DateTime.now();
      final api = FakeApiClient(standardRoutes(alerts: [
        alertJson('c1', 'info', 'brand_new_alert_type', 'Something unusual', now),
      ]));
      await openDetail(tester, api, 'Alert');
      await expandCoachSection(tester);

      expect(find.text('A calm first conversation'), findsOneWidget);
    });
  });

  group('SocialScreen coach integration', () {
    testWidgets('expanding a concern shows the coach card for its concernTypes', (tester) async {
      final api = FakeApiClient({
        ...standardRoutes(),
        'GET /v1/social/events': (_) => {
              'items': [
                {
                  'id': 'se-1',
                  'app': 'whatsapp',
                  'contact': 'Maya',
                  'severity': 'critical',
                  'preview': 'Don\'t tell your parents.',
                  'concernTypes': ['grooming_risk'],
                  'createdAt': DateTime.now().toUtc().toIso8601String(),
                },
              ],
              'meta': {'total': 1},
            },
      });
      await pumpApp(tester, const SocialScreen(childId: 'child-1'), api);
      await flushFakeHttp(tester);

      final scrollable = find.descendant(
        of: find.byKey(const ValueKey('socialSectionsList')),
        matching: find.byWidgetPredicate((w) => w is Scrollable && w.axis == Axis.vertical),
      );
      await tester.scrollUntilVisible(find.text('Maya'), 150, scrollable: scrollable);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Maya'));
      await tester.pumpAndSettle();
      expect(find.text('How to talk about this'), findsOneWidget);

      await tester.scrollUntilVisible(find.text('How to talk about this'), 150, scrollable: scrollable);
      await tester.pumpAndSettle();
      await expandCoachSection(tester);
      expect(find.text('When an adult may be grooming your child'), findsOneWidget);
      expect(find.textContaining('never blame them'), findsOneWidget);
    });
  });
}
