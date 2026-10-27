import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:familyshield_parent/features/children/child_detail_screen.dart';
import 'package:familyshield_parent/features/content/search_safety_screen.dart';
import 'package:familyshield_parent/features/reports/usage_history_screen.dart';
import 'package:familyshield_parent/features/social/social_screen.dart';
import 'package:familyshield_parent/l10n/app_localizations.dart';
import 'package:familyshield_parent/providers/auth_provider.dart';
import 'fake_api_client.dart';
import 'package:familyshield_parent/providers/content_provider.dart';
import 'package:familyshield_parent/providers/social_provider.dart';
import 'package:familyshield_parent/providers/world_class_provider.dart';

/// ADR-0014 amendment, decision 7 / #406 review: each **gated** surface that renders text names the owner on
/// a refusal, and drops the screen's own message.
///
/// The rows override a provider to throw the server's refusal rather than driving a fixture, which is what
/// makes them about the error branch and nothing else.

DioException refusal() => DioException(
      requestOptions: RequestOptions(path: '/v1/gated'),
      response: Response(
        requestOptions: RequestOptions(path: '/v1/gated'),
        statusCode: 403,
        data: {'error': 'permission_required', 'permission': 'social'},
      ),
    );

Future<void> pump(WidgetTester tester, Widget home, List<Override> overrides) async {
  await tester.pumpWidget(ProviderScope(
    overrides: overrides,
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('en'),
      home: home,
    ),
  ));
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));

  testWidgets('search safety names the owner for a refused /v1/content/searches', (tester) async {
    await pump(
      tester,
      const SearchSafetyScreen(childId: 'child-1'),
      [searchEventsProvider('child-1').overrideWith((ref) => throw refusal())],
    );

    expect(find.text(l10n.readPermissionRequired), findsWidgets);
    expect(find.textContaining('Failed to load searches'), findsNothing);
  });

  testWidgets('social concerns names the owner for a refused /v1/social/events', (tester) async {
    await pump(
      tester,
      const SocialScreen(childId: 'child-1'),
      [socialEventsProvider('child-1').overrideWith((ref) => throw refusal())],
    );

    expect(find.text(l10n.readPermissionRequired), findsWidgets);
  });

  testWidgets('browsing history names the owner for a refused /v1/reports/web', (tester) async {
    // The screen builds its own WebHistoryQuery from the user's window/limit, so the override is on the
    // family rather than one argument tuple: the row is about the error branch, not about which window
    // happens to be selected.
    await pump(
      tester,
      const UsageHistoryScreen(childId: 'child-1'),
      [webHistoryProvider.overrideWith((ref, query) => throw refusal())],
    );

    expect(find.textContaining(l10n.readPermissionRequired), findsWidgets);
    // The raw DioException text must not sit under the owner sentence.
    expect(find.textContaining('DioException'), findsNothing);
  });


  testWidgets('location history names the owner for a refused /v1/location/:id/history', (tester) async {
    // The card is below the fold in a lazily-built list, so it is not constructed until it is scrolled
    // to — which is why `find` alone saw nothing the first two times I tried this row.
    final api = FakeApiClient(standardRoutes());
    await tester.pumpWidget(ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        locationHistoryProvider.overrideWith((ref, id) => throw refusal()),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: const ChildDetailScreen(childId: 'child-1'),
      ),
    ));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    final target = find.textContaining(l10n.readPermissionRequired);
    await tester.scrollUntilVisible(target, 300, scrollable: find.byType(Scrollable).first);

    expect(target, findsWidgets);
  });
}
