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

  // Antigravity's F1 (7049793348): only the NEWEST command of a type decides. An old row that never settled
  // must not keep the button blocked after a newer one was acknowledged.
  testWidgets('a stale unconfirmed row does not outvote a newer acknowledged one', (tester) async {
    final now = DateTime.now();
    await pump(tester, history([
      commandJson('c4', 'pause', 'acked', now),
      commandJson('c5', 'pause', 'pending', now.subtract(const Duration(minutes: 2))),
    ]));

    expect(find.byKey(const ValueKey('controlPending-pause')), findsNothing,
        reason: 'the newest pause was acknowledged; an older pending row must not block the control');
  });

  testWidgets('a confirmed command leaves the control usable', (tester) async {
    await pump(tester, history([
      commandJson('c3', 'pause', 'acked', DateTime.now()),
    ]));

    expect(find.byKey(const ValueKey('controlPending-pause')), findsNothing,
        reason: 'an acknowledged command is done; the parent can send another');
  });

  // Antigravity's F2 (7049793348): the button itself must be disabled, not merely covered. `IgnorePointer`
  // stops touch but leaves a TextButton enabled for TalkBack, VoiceOver, Switch Access and Enter/Space, so the
  // check is on the button's own `onPressed`, which is the state every input method honours.
  testWidgets('the pending control is disabled for every input method, not just touch', (tester) async {
    final now = DateTime.now();
    await pump(tester, history([commandJson('c6', 'pause', 'pending', now)]));

    final button = tester.widget<TextButton>(
      find.ancestor(of: find.text('Pause'), matching: find.byType(TextButton)).first,
    );
    expect(button.onPressed, isNull,
        reason: 'a pending control must be unusable from a screen reader or the keyboard too');
  });
}
