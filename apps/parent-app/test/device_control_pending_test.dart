import 'package:familyshield_parent/features/children/child_detail_screen.dart';
import 'package:familyshield_parent/providers/auth_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_api_client.dart';
import 'test_app.dart';

/// #969: a parent tapped Resume expecting apps to work again and nothing happened, because the row never said
/// which control reaches how far and never showed that a request was still waiting on the phone.
///
/// This row pins the second half only: while the newest command of a type is queued and the handset has not
/// confirmed it, that control must say so instead of looking idle. The labels themselves are the Bureaus' and
/// are not changed here.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  Future<void> pump(WidgetTester tester, Map<String, dynamic> history) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final api = FakeApiClient({
      ...standardRoutes(),
      'GET /v1/devices/dev-1/commands/history': (_) => history,
    });
    await tester.pumpWidget(ProviderScope(
      overrides: [apiClientProvider.overrideWithValue(api)],
      child: localizedTestApp(const ChildDetailScreen(childId: 'child-1')),
    ));
    await tester.pumpAndSettle();
  }

  Map<String, dynamic> history(List<Map<String, dynamic>> items) => {'items': items};

  testWidgets('a queued pause shows the control as pending, not idle', (tester) async {
    await pump(tester, history([
      commandJson('c1', 'pause', 'pending', DateTime.now()),
    ]));

    expect(find.byKey(const ValueKey('controlPending-pause')), findsOneWidget,
        reason: 'the POST answered {status: pending}; the control must say the phone has not confirmed');
    expect(find.byKey(const ValueKey('controlPending-resume')), findsNothing,
        reason: 'only the command that is waiting is marked');
  });

  testWidgets('a delivered but unacknowledged command is still pending', (tester) async {
    await pump(tester, history([
      commandJson('c2', 'pause', 'delivered', DateTime.now()),
    ]));

    expect(find.byKey(const ValueKey('controlPending-pause')), findsOneWidget,
        reason: 'delivered means it reached the queue, not that the handset acted on it');
  });

  testWidgets('a confirmed command leaves the control usable', (tester) async {
    await pump(tester, history([
      commandJson('c3', 'pause', 'acked', DateTime.now()),
    ]));

    expect(find.byKey(const ValueKey('controlPending-pause')), findsNothing,
        reason: 'an acknowledged command is done; the parent can send another');
  });
}
