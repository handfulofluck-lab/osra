import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:familyshield_parent/providers/auth_provider.dart';
import 'package:familyshield_parent/providers/world_class_provider.dart';

import 'fake_api_client.dart';

/// #869: the API's HistoryQuerySchema uses z.string().datetime() without
/// offset/local options (services/api/src/routes/location.ts). Its UTC/Z bounds
/// are exercised in services/api/test/geofence.test.ts. Inspect the real
/// provider request here, rather than a separately constructed example.
/// Mutant: remove either .toUtc() call from the history query; this row fails.
void main() {
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
}
