import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:familyshield_parent/features/children/child_detail_screen.dart';
import 'package:familyshield_parent/l10n/app_localizations.dart';
import 'package:familyshield_parent/providers/auth_provider.dart';
import 'package:familyshield_parent/providers/family_provider.dart';
import 'package:familyshield_parent/providers/world_class_provider.dart';

import 'fake_api_client.dart';
import 'test_app.dart';

/// #850: a child that has not reported a location yet must show the empty state, and no exception
/// text ever reaches the parent. Mutant: remove the `statusCode == 404` branch in `locationProvider`
/// (or in `locationHistoryProvider`) and the 404 rows go red; put `'$e'` back in the location tab's
/// error text and the 500 row goes red.
void main() {
  final en = lookupAppLocalizations(const Locale('en'));

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  Map<String, FakeRoute> routes({required Object? latest, Object? history}) => {
        ...standardRoutes(),
        'GET /v1/location/child-1/latest': (_) => latest,
        'GET /v1/location/child-1/history': (_) => history ?? const {'pings': []},
      };

  test('a 404 from the latest-location read is "no location", not an error', () async {
    final container = ProviderContainer(overrides: [
      apiClientProvider.overrideWithValue(FakeApiClient(routes(latest: const FakeHttpError(404)))),
    ]);
    addTearDown(container.dispose);
    expect(await container.read(locationProvider('child-1').future), isNull);
  });

  test('a 404 from the history read is an empty day, not an error', () async {
    final container = ProviderContainer(overrides: [
      apiClientProvider.overrideWithValue(
          FakeApiClient(routes(latest: const {'latest': null}, history: const FakeHttpError(404)))),
    ]);
    addTearDown(container.dispose);
    expect(await container.read(locationHistoryProvider('child-1').future), isEmpty);
  });

  Future<void> openLocationTab(WidgetTester tester, {required List<Override> overrides}) async {
    await tester.pumpWidget(ProviderScope(
      overrides: overrides,
      child: localizedTestApp(const Scaffold(body: ChildDetailScreen(childId: 'child-1'))),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text(en.tabLocation));
    await tester.pumpAndSettle();
  }

  testWidgets('a child with no location yet shows the empty state and no exception text', (tester) async {
    await openLocationTab(tester, overrides: [
      apiClientProvider.overrideWithValue(
          FakeApiClient(routes(latest: const FakeHttpError(404), history: const FakeHttpError(404)))),
    ]);
    expect(find.text(en.noLocationReported), findsOneWidget);
    expect(find.textContaining('DioException'), findsNothing);
  });

  testWidgets('any other failure shows the plain localized line, never the exception', (tester) async {
    final failure = DioException(
      requestOptions: RequestOptions(path: '/v1/location/child-1/latest'),
      response: Response(requestOptions: RequestOptions(path: '/v1/location/child-1/latest'), statusCode: 500),
      type: DioExceptionType.badResponse,
    );
    await openLocationTab(tester, overrides: [
      apiClientProvider.overrideWithValue(FakeApiClient(routes(latest: const {'latest': null}))),
      locationProvider('child-1').overrideWith((ref) => throw failure),
    ]);
    expect(find.text(en.locationLoadFailed(en.tryAgain)), findsOneWidget);
    expect(find.textContaining('DioException'), findsNothing);
  });
}
