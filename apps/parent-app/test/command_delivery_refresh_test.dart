import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:familyshield_parent/features/children/child_detail_screen.dart';
import 'package:familyshield_parent/features/children/command_history_screen.dart';
import 'package:familyshield_parent/providers/auth_provider.dart';

import 'fake_api_client.dart';
import 'test_app.dart';

/// #876: the child's *Command delivery* list kept showing the old rows after a rule save, and pulling down
/// did nothing — the list changed only after leaving the screen and coming back.
///
/// The three halves are: refresh after the save, refresh on pull-down, and refresh when the `rules_applied`
/// frame arrives (the mapping row lives in `realtime_refresh_test.dart`).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  Future<void> pumpScreen(WidgetTester tester, Widget home, FakeApiClient api) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(ProviderScope(
      overrides: [apiClientProvider.overrideWithValue(api)],
      child: localizedTestApp(home),
    ));
    await tester.pumpAndSettle();
  }

  Future<void> flushFakeHttp(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  /// A history that grows on each read, so a refetch is visible as "the newest command changed".
  FakeApiClient growingHistory() {
    var reads = 0;
    return FakeApiClient({
      ...standardRoutes(),
      'GET /v1/devices/dev-1/commands/history': (_) {
        reads++;
        return {
          'items': [
            commandJson(
              reads == 1 ? 'cmd-old' : 'cmd-new',
              'rules_updated',
              'delivered',
              DateTime.now(),
              deliveredAt: DateTime.now(),
            ),
          ],
        };
      },
    });
  }

  testWidgets('pulling down on the child detail refreshes the delivery list', (tester) async {
    final api = growingHistory();
    await pumpScreen(tester, const ChildDetailScreen(childId: 'child-1'), api);

    final firstRead = api.calls('GET', '/v1/devices/dev-1/commands/history').length;
    expect(firstRead, greaterThanOrEqualTo(1));

    // A pull-down on the overview: the gesture had nothing attached to it before this row existed.
    await tester.fling(find.byType(SingleChildScrollView).first, const Offset(0, 400), 1200);
    await flushFakeHttp(tester);
    await tester.pumpAndSettle();

    final after = api.calls('GET', '/v1/devices/dev-1/commands/history').length;
    // Mutant: drop the RefreshIndicator and this is unchanged.
    expect(after, greaterThan(firstRead));
  });

  testWidgets('the full command history screen can be pulled down too', (tester) async {
    final api = growingHistory();
    await pumpScreen(tester, const CommandHistoryScreen(childId: 'child-1'), api);

    final firstRead = api.calls('GET', '/v1/devices/dev-1/commands/history').length;
    await tester.fling(find.byType(ListView).first, const Offset(0, 400), 1200);
    await flushFakeHttp(tester);
    await tester.pumpAndSettle();

    expect(api.calls('GET', '/v1/devices/dev-1/commands/history').length, greaterThan(firstRead));
  });

  /// The save path cannot be observed through a widget here — the provider is not mounted on the rules
  /// screen — so the wiring is pinned the way the Kotlin wiring rows are: by reading the source.
  test('a rule save invalidates the child\'s delivery lists', () {
    final source = File('lib/features/rules/rules_editor_screen.dart').readAsStringSync();
    final save = source.indexOf('Future<void> _save() async');
    final invalidate = source.indexOf('ref.invalidate(deviceCommandHistoryProvider(device.id))');
    expect(save, isNonNegative);
    // Mutant: drop the loop and the list keeps its cached rows until the screen is re-entered.
    expect(invalidate, greaterThan(save));
    expect(source.contains('devicesFor(widget.childId)'), isTrue);
  });
}
