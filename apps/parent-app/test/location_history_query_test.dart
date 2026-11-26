import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:familyshield_parent/features/children/child_detail_screen.dart';
import 'package:familyshield_parent/features/map/child_location_view.dart';
import 'package:familyshield_parent/l10n/app_localizations.dart';
import 'package:familyshield_parent/providers/auth_provider.dart';
import 'package:familyshield_parent/providers/family_provider.dart';
import 'package:familyshield_parent/providers/world_class_provider.dart';

import 'fake_api_client.dart';
import 'test_app.dart';

final _effectsProvider = Provider<RealtimeEffects>(RealtimeEffects.fromRef);

/// #869: the API's HistoryQuerySchema uses z.string().datetime() without
/// offset/local options (services/api/src/routes/location.ts). Its UTC/Z bounds
/// are exercised in services/api/test/geofence.test.ts. Inspect the real
/// provider request here, rather than a separately constructed example.
/// Mutant: remove either .toUtc() call from the history query; this row fails.
void main() {
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  test('history sends UTC/Z bounds for the parent local calendar day',
      () async {
    final api = FakeApiClient({
      'GET /v1/location/child-fictional/history': (_) => const {'pings': []},
    });
    final container = ProviderContainer(overrides: [
      apiClientProvider.overrideWithValue(api),
    ]);
    addTearDown(container.dispose);

    final before = DateTime.now();
    expect(
        await container.read(locationHistoryProvider('child-fictional').future),
        isEmpty);
    final after = DateTime.now();
    final query =
        api.calls('GET', '/v1/location/child-fictional/history').single.query;
    final fromText = query['from'] as String;
    final toText = query['to'] as String;

    // Dart local ISO strings omit Z even on a zero-offset host. The server
    // rejects those as 400; both bounds must explicitly identify UTC.
    expect(fromText, endsWith('Z'),
        reason: 'from must satisfy the API UTC datetime contract');
    expect(toText, endsWith('Z'),
        reason: 'to must satisfy the API UTC datetime contract');
    final from = DateTime.parse(fromText);
    final to = DateTime.parse(toText);
    expect(from.isUtc, isTrue);
    expect(to.isUtc, isTrue);

    // Preserve local midnight as an instant: constructing UTC midnight instead
    // would silently omit early-day pings (or include yesterday) outside UTC.
    // Allow the request to cross midnight without making this row flaky.
    final possibleMidnights = {
      DateTime(before.year, before.month, before.day).toUtc(),
      DateTime(after.year, after.month, after.day).toUtc(),
    };
    expect(possibleMidnights, contains(from));
    expect(to.isBefore(before.toUtc()), isFalse);
    expect(to.isAfter(after.toUtc()), isFalse);
    expect(from.isAfter(to), isFalse);
  });

  // #1055: a failed history load must not stay cached across navigations.
  // Mutant: drop `.autoDispose` from `locationHistoryProvider`; the cached
  // AsyncError survives leaving the Location tab and reopening still shows
  // `locationHistoryLoadFailed` instead of refetching.
  testWidgets(
      'reopening the Location tab refetches after a prior history load error (#1055)',
      (tester) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final en = lookupAppLocalizations(const Locale('en'));
    var failHistory = true;
    final now = DateTime.now();
    final api = FakeApiClient({
      ...standardRoutes(),
      'GET /v1/location/child-1/latest': (_) => {
            'latest': {
              'deviceId': 'dev-1',
              'lat': 25.11318,
              'lng': 55.20034,
              'accuracyM': 15,
              'timestamp': now.toUtc().toIso8601String(),
            },
          },
      'GET /v1/location/child-1/history': (_) => failHistory
          ? const FakeHttpError(500)
          : {
              'pings': [
                {
                  'lat': 25.11318,
                  'lng': 55.20034,
                  'accuracyM': 15,
                  'timestamp': now.toUtc().toIso8601String(),
                },
              ],
            },
    });
    final container = ProviderContainer(overrides: [
      apiClientProvider.overrideWithValue(api),
      placemarkLookupProvider.overrideWithValue((lat, lng, locale) async => const []),
    ]);
    Widget host(bool open) => UncontrolledProviderScope(
          container: container,
          child: localizedTestApp(
            open
                ? const ChildDetailScreen(
                    childId: 'child-1',
                    initialTab: ChildDetailScreen.locationTab,
                  )
                : const Scaffold(body: SizedBox()),
          ),
        );

    await tester.pumpWidget(host(true));
    await tester.pumpAndSettle();
    expect(find.text(en.locationHistoryLoadFailed), findsOneWidget);

    // Leave the Location tab, then return once the server responds cleanly.
    failHistory = false;
    await tester.pumpWidget(host(false));
    await tester.pumpAndSettle();
    await tester.pumpWidget(host(true));
    await tester.pumpAndSettle();

    expect(find.text(en.locationHistoryLoadFailed), findsNothing);
    expect(find.text(en.todaysRoute), findsOneWidget);
    expect(api.calls('GET', '/v1/location/child-1/history'), hasLength(2));

    await tester.pumpWidget(const SizedBox());
    container.dispose();
  });

  // #1055: a realtime `location` event must invalidate history alongside latest.
  // Mutant: remove `_ref.invalidate(locationHistoryProvider(childId))` from
  // `RiverpodRealtimeEffects.invalidateLocation`; history stays stuck on the
  // prior error while `locationProvider` updates.
  test(
      'a realtime location event invalidates locationHistoryProvider alongside locationProvider (#1055)',
      () async {
    var failHistory = true;
    final now = DateTime.now().toUtc();
    final api = FakeApiClient({
      ...standardRoutes(),
      'GET /v1/location/child-1/latest': (_) => {
            'latest': {
              'deviceId': 'dev-1',
              'lat': 25.11318,
              'lng': 55.20034,
              'accuracyM': 15,
              'timestamp': now.toIso8601String(),
            },
          },
      'GET /v1/location/child-1/history': (_) => failHistory
          ? const FakeHttpError(500)
          : {
              'pings': [
                {
                  'lat': 25.11318,
                  'lng': 55.20034,
                  'accuracyM': 15,
                  'timestamp': now.toIso8601String(),
                },
              ],
            },
    });
    final container = ProviderContainer(overrides: [
      apiClientProvider.overrideWithValue(api),
    ]);
    addTearDown(container.dispose);

    // Keep the autoDispose provider subscribed like a mounted Location tab.
    final sub = container.listen(locationHistoryProvider('child-1'), (_, __) {});
    addTearDown(sub.close);

    await expectLater(
      container.read(locationHistoryProvider('child-1').future),
      throwsA(anything),
    );
    expect(api.calls('GET', '/v1/location/child-1/history'), hasLength(1));

    // A fresh location arrives over /v1/ws.
    failHistory = false;
    applyRealtimeMessage(container.read(_effectsProvider), {
      'type': 'location',
      'payload': {'childId': 'child-1', 'ts': now.toIso8601String()},
    });

    final pings = await container.read(locationHistoryProvider('child-1').future);
    expect(pings, hasLength(1));
    expect(pings.single.lat, closeTo(25.11318, 1e-6));
    expect(api.calls('GET', '/v1/location/child-1/history'), hasLength(2));
  });
}
