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

  // #969: the defect was that "Resume" and "Resume net" sat side by side and neither said what it reached.
  // The four scoped labels already exist in both catalogs, so this needs no new copy — only that the card uses
  // them. This row fails if the card goes back to the ambiguous pair.
  testWidgets('the card names the scope of each control', (tester) async {
    await pump(tester, history(const []));

    expect(find.text('Pause device'), findsOneWidget, reason: 'the per-handset pause names its scope');
    expect(find.text('Resume device'), findsOneWidget);
    expect(find.text('Pause internet'), findsOneWidget, reason: 'the child-wide pause names its scope');
    expect(find.text('Pause net'), findsNothing, reason: 'the ambiguous label is gone');
    expect(find.text('Resume net'), findsNothing);
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
      find.ancestor(of: find.text('Pause device'), matching: find.byType(TextButton)).first,
    );
    expect(button.onPressed, isNull,
        reason: 'a pending control must be unusable from a screen reader or the keyboard too');
  });

  // #969, the scope half: the card must say which controls reach one handset and which reach the family.
  // These two keys are the Arabic Language Bureau's (`scopeThisDevice`, `scopeAllDevices`), and the rows fail
  // if the card goes back to one unnamed row where "Resume" and "Resume net" sit side by side.
  testWidgets('the card names the scope of each group of controls', (tester) async {
    await pump(tester, history(const []));

    // Each wording is bound to its own keyed heading. Finding the two strings separately would pass with the
    // labels swapped, which is the exact mistake this row exists to catch (Codex, 7118188485).
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('scopeThisDevice')),
        matching: find.text('This device'),
      ),
      findsOneWidget,
      reason: 'the per-handset controls are grouped under a label that says so',
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('scopeAllDevices')),
        matching: find.text('All paired devices'),
      ),
      findsOneWidget,
      reason: 'the internet control is family-wide and must not read as a per-handset command',
    );
    // And neither heading may carry the other's wording.
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('scopeThisDevice')),
        matching: find.text('All paired devices'),
      ),
      findsNothing,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('scopeAllDevices')),
        matching: find.text('This device'),
      ),
      findsNothing,
    );
  });

  // The line, not the tooltip: #974 marked the button with a tooltip, which a parent on a phone never sees.
  // The Bureau's wording names *this* device, so the line is visible on the card (604 `7116638057`).
  testWidgets('a queued per-handset command shows the waiting line naming this device', (tester) async {
    await pump(tester, history([commandJson('c10', 'pause', 'pending', DateTime.now())]));

    expect(find.byKey(const ValueKey('deviceControlPending')), findsOneWidget);
    expect(find.text('Waiting for this device'), findsOneWidget);
    expect(find.byKey(const ValueKey('deviceControlFailed')), findsNothing,
        reason: 'waiting and refused are different sentences');
  });

  testWidgets('a failed per-handset command shows the refusal line', (tester) async {
    await pump(tester, history([commandJson('c11', 'pause', 'failed', DateTime.now())]));

    expect(find.byKey(const ValueKey('deviceControlFailed')), findsOneWidget);
    expect(find.text("This device couldn't apply the change"), findsOneWidget);
    expect(find.byKey(const ValueKey('deviceControlPending')), findsNothing);
  });

  // Mutant: showing the line for any command at all, including the family-wide internet control. The line is
  // about this handset; an internet pause is not a per-device command and must not produce it.
  testWidgets('the family-wide internet command does not drive the per-handset line', (tester) async {
    await pump(tester, history([commandJson('c12', 'pause_internet', 'pending', DateTime.now())]));

    expect(find.byKey(const ValueKey('deviceControlPending')), findsNothing);
    expect(find.byKey(const ValueKey('deviceControlFailed')), findsNothing);
  });

  testWidgets('an acknowledged command leaves no line on the card', (tester) async {
    await pump(tester, history([commandJson('c13', 'pause', 'acked', DateTime.now())]));

    expect(find.byKey(const ValueKey('deviceControlPending')), findsNothing,
        reason: 'a confirmed command is done; the card should not keep explaining it');
    expect(find.byKey(const ValueKey('deviceControlFailed')), findsNothing);
  });

  // The Arabic half: the four strings are the Bureau's, verbatim, and the labels must render in an Arabic
  // locale with the same meaning as English — a missing catalog entry would show the English fallback.
  testWidgets('the scope labels and the waiting line render in Arabic', (tester) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final api = FakeApiClient({
      ...standardRoutes(),
      'GET /v1/devices/dev-1/commands/history': (_) =>
          history([commandJson('c14', 'pause', 'pending', DateTime.now())]),
    });
    await tester.pumpWidget(ProviderScope(
      overrides: [apiClientProvider.overrideWithValue(api)],
      child: localizedTestApp(
        const ChildDetailScreen(childId: 'child-1'),
        locale: const Locale('ar'),
        textDirection: TextDirection.rtl,
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('هذا الجهاز'), findsOneWidget);
    expect(find.text('كل الأجهزة المقترنة'), findsOneWidget);
    expect(find.text('بانتظار تأكيد هذا الجهاز'), findsOneWidget);
    expect(tester.takeException(), isNull, reason: '320 px in Arabic must not overflow');
  });

}
