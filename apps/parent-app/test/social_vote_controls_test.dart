import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:familyshield_parent/api/models.dart';
import 'package:familyshield_parent/features/social/social_vote_controls.dart';
import 'package:familyshield_parent/providers/auth_provider.dart';
import 'package:familyshield_parent/providers/family_provider.dart';
import 'package:familyshield_parent/providers/social_vote_provider.dart';
import 'package:familyshield_parent/theme/app_theme.dart';
import 'package:familyshield_parent/theme/app_tokens.dart';

import 'fake_api_client.dart';
import 'test_app.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  Map<String, dynamic> feedback(String verdict, {String parentName = 'Lina'}) =>
      {
        'verdict': verdict,
        'parentDisplayName': parentName,
        'firstVotedAt': '2026-11-24T10:01:00.000Z',
        'lastChangedAt': '2026-11-24T10:02:00.000Z',
      };

  Future<FakeApiClient> pumpControls(
    WidgetTester tester, {
    bool compact = false,
    Locale locale = const Locale('en'),
    double width = 390,
    double textScale = 1,
    String? initialVerdict,
    bool ownVoteMatchesLatest = true,
    String? initialOwnVerdict,
    String voterName = 'Lina',
    Map<String, FakeRoute>? routes,
    bool dark = false,
  }) async {
    final api = FakeApiClient(routes ??
        {
          ...standardRoutes(),
          'POST /v1/social/events/event-1/feedback': (request) => {
                'feedback': feedback(request.body['verdict'] as String,
                    parentName: voterName),
              },
          'DELETE /v1/social/events/event-1/feedback': (_) =>
              {'feedback': null},
        });
    final container = ProviderContainer(overrides: [
      apiClientProvider.overrideWithValue(api),
      familyProvider.overrideWith(
          (ref) => FamilyOverview.fromJson(familyMeTwoChildren())),
    ]);
    addTearDown(container.dispose);
    if (initialVerdict != null) {
      final ownVerdict =
          ownVoteMatchesLatest ? initialVerdict : initialOwnVerdict;
      container.read(socialVoteProvider('event-1').notifier).syncFromEvent(
            SocialConcernEvent(
              id: 'event-1',
              app: 'whatsapp',
              contact: 'Maya',
              severity: 'warning',
              preview: '',
              latestFeedbackVerdict: initialVerdict,
              latestFeedbackParentDisplayName: voterName,
              latestFeedbackFirstVotedAt: DateTime.utc(2026, 11, 24, 10, 1),
              latestFeedbackLastChangedAt: DateTime.utc(2026, 11, 24, 10, 2),
              ownFeedbackVerdict: ownVerdict,
              ownFeedbackFirstVotedAt:
                  ownVerdict == null ? null : DateTime.utc(2026, 11, 24, 10, 1),
              ownFeedbackLastChangedAt:
                  ownVerdict == null ? null : DateTime.utc(2026, 11, 24, 10, 2),
            ),
          );
    }
    tester.view.physicalSize = Size(width, 900);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      tester.platformDispatcher.clearTextScaleFactorTestValue();
    });
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: localizedTestApp(
        Scaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: SocialVoteControls(eventId: 'event-1', compact: compact),
          ),
        ),
        locale: locale,
        textDirection: locale.languageCode == 'ar' ? TextDirection.rtl : null,
        theme: AppTheme.light,
        darkTheme: AppTheme.dark,
        themeMode: dark ? ThemeMode.dark : ThemeMode.light,
      ),
    ));
    await tester.pumpAndSettle();
    return api;
  }

  testWidgets(
      'unset detail state shows the question, two outlined choices and help',
      (tester) async {
    await pumpControls(tester);

    expect(find.text('Was OSRA right to flag this?'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, 'Concerning'), findsOneWidget);
    expect(
        find.widgetWithText(OutlinedButton, 'Not concerning'), findsOneWidget);
    expect(find.text('Your answer helps OSRA check messages better.'),
        findsOneWidget);
    expect(find.byIcon(Icons.check), findsNothing);
  });

  testWidgets(
      'selected detail choice is amber with a check and inert; the other changes it',
      (tester) async {
    final api = await pumpControls(tester, initialVerdict: 'concerning');

    final selected = find.widgetWithText(FilledButton, 'Concerning');
    expect(selected, findsOneWidget);
    expect(tester.widget<FilledButton>(selected).onPressed, isNotNull);
    expect(find.byIcon(Icons.check), findsOneWidget);
    final background = tester
        .widget<FilledButton>(selected)
        .style
        ?.backgroundColor
        ?.resolve({});
    expect(background, isNot(AppTokens.light.surfaceVariant));
    expect(find.text('\u2068Lina\u2069: Concerning'), findsOneWidget);

    await tester.tap(selected);
    await tester.pumpAndSettle();
    expect(api.calls('POST', '/v1/social/events/event-1/feedback'), isEmpty);

    await tester.tap(find.widgetWithText(OutlinedButton, 'Not concerning'));
    await tester.pumpAndSettle();
    expect(api.calls('POST', '/v1/social/events/event-1/feedback').last.body,
        {'verdict': 'not_concerning'});
    expect(
        tester
            .widget<FilledButton>(
                find.widgetWithText(FilledButton, 'Not concerning'))
            .onPressed,
        isNotNull);
  });

  testWidgets(
      'selected detail choices keep tonal contrast and selected enabled semantics',
      (tester) async {
    // Mutant: a null selected callback activates Material's disabled grey
    // colors and drops enabled semantics; omitting Semantics.selected hides
    // which choice is active from accessibility services.
    final semanticsHandle = tester.ensureSemantics();

    for (final dark in const [false, true]) {
      for (final choice in const [
        ('concerning', 'Concerning'),
        ('not_concerning', 'Not concerning'),
      ]) {
        final api = await pumpControls(
          tester,
          initialVerdict: choice.$1,
          dark: dark,
        );
        final tokens = dark ? AppTokens.dark : AppTokens.light;
        final selected = find.widgetWithText(FilledButton, choice.$2);
        final material = tester.widget<Material>(find.descendant(
          of: selected,
          matching: find.byType(Material),
        ));
        final expectedBackground = choice.$1 == 'concerning'
            ? tokens.severityWarning.withValues(alpha: 0.24)
            : tokens.surfaceVariant;
        final expectedForeground = choice.$1 == 'concerning'
            ? tokens.severityWarningText
            : tokens.onSurface;

        expect(selected, findsOneWidget);
        expect(find.byIcon(Icons.check), findsOneWidget);
        expect(material.color, expectedBackground,
            reason: '${choice.$1} ${dark ? 'dark' : 'light'} background');
        expect(material.textStyle?.color, expectedForeground,
            reason: '${choice.$1} ${dark ? 'dark' : 'light'} foreground');
        expect(tester.widget<FilledButton>(selected).onPressed, isNotNull);
        final semantics = tester.getSemantics(selected).flagsCollection;
        expect(semantics.isButton, isTrue);
        expect(semantics.isSelected.toBoolOrNull(), isTrue);
        expect(semantics.isEnabled.toBoolOrNull(), isTrue);
        expect(
          find.widgetWithText(
            OutlinedButton,
            choice.$1 == 'concerning' ? 'Not concerning' : 'Concerning',
          ),
          findsOneWidget,
        );

        await tester.tap(selected);
        await tester.pumpAndSettle();
        expect(
            api.calls('POST', '/v1/social/events/event-1/feedback'), isEmpty);
      }
    }
    semanticsHandle.dispose();
  });

  testWidgets(
      'co-parent latest hides Clear but does not block a matching own vote',
      (tester) async {
    final api = await pumpControls(
      tester,
      initialVerdict: 'concerning',
      ownVoteMatchesLatest: false,
      initialOwnVerdict: null,
    );

    expect(find.text('Clear vote'), findsNothing);
    expect(find.text('\u2068Lina\u2069: Concerning'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, 'Concerning'), findsOneWidget);

    await tester.tap(find.widgetWithText(OutlinedButton, 'Concerning'));
    await tester.pumpAndSettle();
    expect(
        api.calls('POST', '/v1/social/events/event-1/feedback'), hasLength(1));
    expect(find.text('Clear vote'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets(
      'Clear vote deletes, confirms with Undo, and is absent from compact rows',
      (tester) async {
    final api = await pumpControls(tester,
        initialVerdict: 'concerning', voterName: 'QA Parent');

    final clear = find.widgetWithText(TextButton, 'Clear vote');
    expect(clear, findsOneWidget);
    expect(tester.getSize(clear).height, greaterThanOrEqualTo(48));

    await tester.tap(clear);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(api.calls('DELETE', '/v1/social/events/event-1/feedback'),
        hasLength(1));
    expect(find.text('Vote cleared'), findsOneWidget);
    expect(find.text('Undo'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, 'Concerning'), findsOneWidget);
    expect(find.text('Clear vote'), findsNothing);

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(api.calls('POST', '/v1/social/events/event-1/feedback').last.body,
        {'verdict': 'concerning'});

    await pumpControls(tester, compact: true, initialVerdict: 'not_concerning');
    expect(find.text('Clear vote'), findsNothing);
  });

  testWidgets('Arabic Clear vote uses the approved labels', (tester) async {
    await pumpControls(tester,
        locale: const Locale('ar'),
        width: 320,
        textScale: 2,
        initialVerdict: 'not_concerning');

    final clear = find.text('إلغاء إجابتي');
    expect(clear, findsOneWidget);
    expect(
        find.bySemanticsLabel('إلغاء إجابتك عن هذه الرسالة'), findsOneWidget);
    await tester.tap(clear);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('أُلغيت إجابتك'), findsOneWidget);
    expect(find.text('تراجع'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'compact unset buttons show visible labels with 48dp targets and selected pill reopens choices',
      (tester) async {
    // Mutant: reverting _compactChoice to icon-only IconButton drops the visible
    // 'Concerning' / 'Not concerning' text labels and breaks the OutlinedButton checks.
    await pumpControls(tester, compact: true);

    expect(find.widgetWithText(OutlinedButton, 'Concerning'), findsOneWidget);
    expect(
        find.widgetWithText(OutlinedButton, 'Not concerning'), findsOneWidget);
    for (final label in ['Mark as concerning', 'Mark as not concerning']) {
      final button = find.byTooltip(label);
      expect(button, findsOneWidget);
      expect(find.bySemanticsLabel(label), findsOneWidget);
      final size = tester.getSize(button);
      expect(size.width, greaterThanOrEqualTo(48));
      expect(size.height, greaterThanOrEqualTo(48));
    }

    await tester.tap(find.widgetWithText(OutlinedButton, 'Concerning'));
    await tester.pumpAndSettle();
    final pill = find.widgetWithText(FilledButton, 'Concerning');
    expect(pill, findsOneWidget);
    expect(find.byTooltip('Mark as concerning'), findsNothing);

    await tester.tap(pill);
    await tester.pumpAndSettle();
    expect(find.byTooltip('Mark as concerning'), findsOneWidget);
    expect(
        tester
            .widget<FilledButton>(
                find.widgetWithText(FilledButton, 'Concerning'))
            .onPressed,
        isNull);
    expect(find.byTooltip('Mark as not concerning'), findsOneWidget);
    expect(
        find.widgetWithText(OutlinedButton, 'Not concerning'), findsOneWidget);
  });

  testWidgets(
      'U100: compact cast vote can be changed by tapping the chosen chip then the other button',
      (tester) async {
    // Mutant: disabling _selectedPill.onPressed or failing to reset _editing on
    // _cast breaks reopening both choices or switching to Not concerning.
    final api = await pumpControls(tester, compact: true);

    await tester.tap(find.widgetWithText(OutlinedButton, 'Concerning'));
    await tester.pumpAndSettle();
    expect(api.calls('POST', '/v1/social/events/event-1/feedback'),
        hasLength(1));
    expect(api.calls('POST', '/v1/social/events/event-1/feedback').last.body,
        {'verdict': 'concerning'});
    final chosenChip = find.widgetWithText(FilledButton, 'Concerning');
    expect(chosenChip, findsOneWidget);

    await tester.tap(chosenChip);
    await tester.pumpAndSettle();
    expect(find.widgetWithText(FilledButton, 'Concerning'), findsOneWidget);
    final notConcerningBtn =
        find.widgetWithText(OutlinedButton, 'Not concerning');
    expect(notConcerningBtn, findsOneWidget);

    await tester.tap(notConcerningBtn);
    await tester.pumpAndSettle();
    final posts = api.calls('POST', '/v1/social/events/event-1/feedback');
    expect(posts, hasLength(2));
    expect(posts.last.body, {'verdict': 'not_concerning'});
    expect(find.widgetWithText(FilledButton, 'Not concerning'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, 'Concerning'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets(
      'not-concerning compact pill uses the neutral surface and localized voter line',
      (tester) async {
    await pumpControls(tester, compact: true, initialVerdict: 'not_concerning');

    final pill = find.widgetWithText(FilledButton, 'Not concerning');
    expect(pill, findsOneWidget);
    expect(
        tester.widget<FilledButton>(pill).style?.backgroundColor?.resolve({}),
        AppTokens.light.surfaceVariant);
    expect(find.text('\u2068Lina\u2069: Not concerning'), findsOneWidget);
  });

  testWidgets(
      'a vote shows a four-second Thanks snackbar whose Undo sends DELETE',
      (tester) async {
    final api = await pumpControls(tester);

    await tester.tap(find.text('Concerning'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Thanks, noted'), findsOneWidget);
    expect(find.text('Undo'), findsOneWidget);
    final snackBar = tester.widget<SnackBar>(find.byType(SnackBar));
    expect(snackBar.duration, const Duration(seconds: 4));

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(api.calls('DELETE', '/v1/social/events/event-1/feedback'),
        hasLength(1));
    expect(find.widgetWithText(OutlinedButton, 'Concerning'), findsOneWidget);
  });

  testWidgets('Thanks disappears after its four-second duration',
      (tester) async {
    await pumpControls(tester);

    await tester.tap(find.text('Concerning'));
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.text('Thanks, noted'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(find.text('Thanks, noted'), findsNothing);
  });

  testWidgets('failed optimistic vote keeps its pill, shows Saving and retries',
      (tester) async {
    var attempts = 0;
    final api = await pumpControls(tester, routes: {
      ...standardRoutes(),
      'POST /v1/social/events/event-1/feedback': (_) {
        attempts++;
        return attempts == 1
            ? const FakeNetworkError()
            : {'feedback': feedback('concerning')};
      },
      'DELETE /v1/social/events/event-1/feedback': (_) => {'feedback': null},
    });

    await tester.tap(find.text('Concerning'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(FilledButton, 'Concerning'), findsOneWidget);
    expect(find.text('Saving…'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);

    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(attempts, 2);
    expect(
        api.calls('POST', '/v1/social/events/event-1/feedback'), hasLength(2));
    expect(find.text('Saving…'), findsNothing);
  });

  testWidgets('403 hides vote controls instead of offering a permanent retry',
      (tester) async {
    await pumpControls(tester, routes: {
      ...standardRoutes(),
      'POST /v1/social/events/event-1/feedback': (_) =>
          const FakeHttpError(403, {'error': 'permission_required'}),
    });

    await tester.tap(find.text('Concerning'));
    await tester.pumpAndSettle();

    expect(find.text('Was OSRA right to flag this?'), findsNothing);
    expect(find.text('Saving…'), findsNothing);
    expect(find.text('Retry'), findsNothing);
    await tester.pump(const Duration(seconds: 5));
  });

  for (final locale in [const Locale('en'), const Locale('ar')]) {
    testWidgets(
        'detail choices wrap below the question at 320px and 200% in ${locale.languageCode}',
        (tester) async {
      await pumpControls(tester, locale: locale, width: 320, textScale: 2);

      final question = find.text(locale.languageCode == 'ar'
          ? 'هل هذه الرسالة مقلقة فعلًا؟'
          : 'Was OSRA right to flag this?');
      final concerning =
          find.text(locale.languageCode == 'ar' ? 'مقلقة' : 'Concerning');
      expect(question, findsOneWidget);
      expect(concerning, findsOneWidget);
      expect(tester.getTopLeft(concerning).dy,
          greaterThan(tester.getRect(question).bottom));
      expect(tester.takeException(), isNull);
      if (locale.languageCode == 'ar') {
        expect(find.text('غير مقلقة'), findsOneWidget);
        expect(
            find.text(
                'إجابتك تساعد تطبيق أسرة للأطفال على فحص الرسائل بدقة أكبر.'),
            findsOneWidget);
        expect(Directionality.of(tester.element(question)), TextDirection.rtl);
      }
    });
  }

  testWidgets(
      'Arabic compact controls expose the approved labels, thanks and Undo',
      (tester) async {
    // Mutant: omitting visible Arabic labels on compact buttons fails the
    // OutlinedButton 'مقلقة' / 'غير مقلقة' assertions before voting.
    await pumpControls(tester,
        compact: true, locale: const Locale('ar'), width: 320, textScale: 2);

    expect(find.widgetWithText(OutlinedButton, 'مقلقة'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, 'غير مقلقة'), findsOneWidget);
    expect(find.bySemanticsLabel('اعتبار الرسالة مقلقة'), findsOneWidget);
    expect(find.bySemanticsLabel('اعتبار الرسالة غير مقلقة'), findsOneWidget);
    await tester.tap(find.widgetWithText(OutlinedButton, 'مقلقة'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('شكرًا، سُجّلت إجابتك'), findsOneWidget);
    expect(find.text('تراجع'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'مقلقة'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
