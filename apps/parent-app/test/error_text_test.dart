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
