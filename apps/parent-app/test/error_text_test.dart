import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:familyshield_parent/features/reports/reports_screen.dart';
import 'package:familyshield_parent/features/reports/usage_history_screen.dart';
import 'package:familyshield_parent/features/social/social_screen.dart';
import 'package:familyshield_parent/l10n/l10n.dart';
import 'package:familyshield_parent/providers/auth_provider.dart';
import 'package:familyshield_parent/widgets/error_retry_view.dart';

import 'fake_api_client.dart';
import 'test_app.dart';

/// #841 condition 1 (UI/UX Bureau, 18 Nov 00:46Z): a failed read shows a sentence, never the raw exception.
///
/// The defect was `detail: '$e'` on the history screens and `reportLoadFailed('$e')` /
/// `rulesLoadFailed('$e')` on reports, rules and social — which put «DioException [bad response]: null» on a
/// parent's screen. A row per screen, because a fix to one and not the others is exactly how it shipped.
///
/// Mutant for every row below: pass the exception into the message again and the raw text reappears, so the
/// "no raw text" assertion goes red while the screen still renders something.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({'jwt': 'jwt-token'});
    SharedPreferences.setMockInitialValues({});
  });

  /// The strings no parent should ever read. `null` is here because it is what Dio's message ends with.
  void expectNoRawException(WidgetTester tester) {
    for (final raw in ['DioException', 'Exception', 'bad response', ': null', 'null']) {
      expect(find.textContaining(raw), findsNothing, reason: 'raw "$raw" reached the screen');
    }
  }

  Future<void> pump(WidgetTester tester, Widget home, FakeApiClient api) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [apiClientProvider.overrideWithValue(api)],
      child: localizedTestApp(home),
    ));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pumpAndSettle();
  }

  testWidgets('a 500 on the screen-time screen shows a sentence, not the exception', (tester) async {
    final api = FakeApiClient({
      ...standardRoutes(),
      'GET /v1/reports/usage': (_) => const FakeHttpError(500),
      'GET /v1/reports/web': (_) => const FakeHttpError(500),
    });
    await pump(tester, const UsageHistoryScreen(childId: 'child-1'), api);

    expect(find.text(l10nFor().couldNotLoadScreenTime), findsOneWidget);
    expect(find.text('Try again'), findsWidgets);
    expectNoRawException(tester);
  });

  testWidgets('a 500 on the reports screen shows a sentence, not the exception', (tester) async {
    final api = FakeApiClient({
      ...standardRoutes(),
      'GET /v1/reports/summary': (_) => const FakeHttpError(500),
    });
    await pump(tester, const ReportsScreen(childId: 'child-1'), api);

    expect(find.text(l10nFor().reportLoadFailed), findsOneWidget);
    expectNoRawException(tester);
  });

  /// Polish item 1 (Claude on #50, from the UI/UX Bureau's follow-up): the sentence said "try again" and the
  /// screen offered nothing to press. Mutant: put the bare `Text(friendlyErrorText(...))` back and the retry
  /// assertion goes red while the sentence assertion still passes — which is how it shipped.
  testWidgets('a failed social section offers a retry that refetches', (tester) async {
    // The monitoring section is the first one on the screen, so it is the one this row drives; the other
    // three sites use the same widget with their own provider.
    final api = FakeApiClient({
      ...standardRoutes(),
      'GET /v1/rules/child-1': (_) => const FakeHttpError(500),
    });
    await pump(tester, const SocialScreen(childId: 'child-1'), api);

    expect(find.byType(ErrorRetryView), findsWidgets);
    // Antigravity's M3: swap `friendlyErrorText` for `e.toString()` and this pair goes red — the row
    // asserted the retry but not that the *sentence* was the one the Bureau issued.
    expect(find.text(l10nFor().rulesLoadFailed), findsWidgets);
    expectNoRawException(tester);

    final rulesBefore = api.calls('GET', '/v1/rules/child-1').length;
    final socialBefore = api.calls('GET', '/v1/social/events').length;
    final activityBefore = api.calls('GET', '/v1/reports/activity').length;

    await tester.tap(find.text('Retry').first);
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pumpAndSettle();

    expect(api.calls('GET', '/v1/rules/child-1').length, greaterThan(rulesBefore));
    // Antigravity's M4: an `onRetry` that invalidated its siblings would survive without these two —
    // "only the section that failed is re-requested" is a claim the row has to make good.
    expect(api.calls('GET', '/v1/social/events').length, socialBefore);
    expect(api.calls('GET', '/v1/reports/activity').length, activityBefore);
  });

  /// Antigravity's M5: in an 800×600 viewport the lazy list never builds Calls & SMS, so a row that only
  /// looks at the top of the screen cannot see `friendlyErrorText` replace it with `e.toString()`. This row
  /// scrolls to the section and asserts the sentence and the absence of raw text there.
  testWidgets('a failed Calls & SMS section shows the sentence, not the exception', (tester) async {
    final api = FakeApiClient({
      ...standardRoutes(),
      'GET /v1/reports/activity': (_) => const FakeHttpError(500),
    });
    await pump(tester, const SocialScreen(childId: 'child-1'), api);

    final section = find.text(l10nFor().callsAndTexts);
    await tester.scrollUntilVisible(section, 200, scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();

    expect(find.text(l10nFor().rulesLoadFailed), findsWidgets);
    expectNoRawException(tester);
  });

  testWidgets('a 500 on the social screen shows a sentence, not the exception', (tester) async {
    final api = FakeApiClient({
      ...standardRoutes(),
      'GET /v1/reports/activity': (_) => const FakeHttpError(500),
    });
    await pump(tester, const SocialScreen(childId: 'child-1'), api);

    // The section may render its own empty/refusal copy rather than the rules sentence; the row's subject is
    // the raw text, so it asserts that and that something rendered, not which sentence won.
    expect(find.byType(SocialScreen), findsOneWidget);
    expectNoRawException(tester);
  });
}

AppLocalizations l10nFor() => lookupAppLocalizations(const Locale('en'));
