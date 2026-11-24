import 'package:familyshield_parent/api/models.dart';
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

  // #969 + U59 (7119037302, 7047663129): the card names the scope of each control AND shows only ONE
  // Pause/Resume device control following the server-confirmed state (never both buttons at once).
  testWidgets('the card names the scope of each control and shows only Pause device when not paused', (tester) async {
    await pump(tester, history(const []));

    expect(find.text('Pause device'), findsOneWidget, reason: 'the per-handset pause names its scope');
    expect(find.text('Resume device'), findsNothing, reason: 'U59: never show both Pause and Resume at once');
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
    expect(find.text('Resume device'), findsOneWidget,
        reason: 'U59: once pause is server-confirmed (acked), the single control flips to Resume device');
    expect(find.text('Pause device'), findsNothing);
  });

  // Antigravity's F2 (7049793348): the button itself must be disabled, not merely covered. `IgnorePointer`
  // stops touch but leaves a button enabled for TalkBack, VoiceOver, Switch Access and Enter/Space, so the
  // check is on the button's own `onPressed`, which is the state every input method honours.
  testWidgets('the pending control is disabled for every input method, not just touch', (tester) async {
    final now = DateTime.now();
    await pump(tester, history([commandJson('c6', 'pause', 'pending', now)]));

    // U61 (7120371019): while waiting for the handset, the disabled button shows "Pausing…".
    expect(find.text('Pausing…'), findsOneWidget);
    final button = tester.widget<ButtonStyleButton>(
      find.ancestor(of: find.text('Pausing…'), matching: find.bySubtype<ButtonStyleButton>()).first,
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
    expect(find.text('جارٍ إيقاف الجهاز…'), findsOneWidget);
    expect(find.text('بانتظار تأكيد هذا الجهاز'), findsOneWidget);
    expect(tester.takeException(), isNull, reason: '320 px in Arabic must not overflow');
  });

  group('U59: single server-confirmed Pause/Resume device control (#650, 7047663129)', () {
    test('resolveDevicePauseControlState follows server-confirmed acked state and pending gate', () {
      // Mutant 1: flipping confirmedPaused on a pending pause instead of acked breaks the pending-pause assertion.
      // Mutant 2: letting a stale pending row block after a newer acked row breaks the stale-row assertion.
      final t0 = DateTime.utc(2026, 11, 24, 9, 0);
      DeviceCommand cmd(String id, String type, String status, int minOffset) =>
          DeviceCommand.fromJson(commandJson(id, type, status, t0.add(Duration(minutes: minOffset))));

      // Empty history -> not paused, idle -> Pause device
      var s = resolveDevicePauseControlState(const []);
      expect(s.confirmedPaused, isFalse);
      expect(s.activeCommand, 'pause');
      expect(s.waiting, isFalse);

      // Queued pause (pending) -> NOT confirmed paused yet, disabled waiting
      s = resolveDevicePauseControlState([cmd('1', 'pause', 'pending', 1)]);
      expect(s.confirmedPaused, isFalse);
      expect(s.activeCommand, 'pause');
      expect(s.waiting, isTrue);
      expect(s.pendingCommand, 'pause');

      // Acked pause -> confirmed paused, idle -> Resume device
      s = resolveDevicePauseControlState([cmd('1', 'pause', 'acked', 1)]);
      expect(s.confirmedPaused, isTrue);
      expect(s.activeCommand, 'resume');
      expect(s.waiting, isFalse);

      // Queued resume after acked pause -> still confirmed paused until handset confirms, disabled waiting
      s = resolveDevicePauseControlState([
        cmd('2', 'resume', 'pending', 2),
        cmd('1', 'pause', 'acked', 1),
      ]);
      expect(s.confirmedPaused, isTrue);
      expect(s.activeCommand, 'resume');
      expect(s.waiting, isTrue);
      expect(s.pendingCommand, 'resume');

      // Acked resume -> flips back to Pause device, idle
      s = resolveDevicePauseControlState([
        cmd('2', 'resume', 'acked', 2),
        cmd('1', 'pause', 'acked', 1),
      ]);
      expect(s.confirmedPaused, isFalse);
      expect(s.activeCommand, 'pause');
      expect(s.waiting, isFalse);

      // Failed resume -> still paused, button re-enabled so parent can retry
      s = resolveDevicePauseControlState([
        cmd('2', 'resume', 'failed', 2),
        cmd('1', 'pause', 'acked', 1),
      ]);
      expect(s.confirmedPaused, isTrue);
      expect(s.activeCommand, 'resume');
      expect(s.waiting, isFalse);
    });

    testWidgets('queued resume disables button with Resuming… (U61) and never shows Pause device until acked', (tester) async {
      // Mutant: rendering both buttons, showing the idle label instead of Resuming…, or flipping back to Pause before resume is acked fails this row.
      final now = DateTime.now();
      await pump(tester, history([
        commandJson('r1', 'resume', 'pending', now),
        commandJson('p1', 'pause', 'acked', now.subtract(const Duration(minutes: 1))),
      ]));

      expect(find.text('Resuming…'), findsOneWidget);
      expect(find.text('Resume device'), findsNothing);
      expect(find.text('Pause device'), findsNothing);
      expect(find.byKey(const ValueKey('controlPending-resume')), findsOneWidget);
      expect(find.byKey(const ValueKey('deviceAction-pauseFullRow-dev-1')), findsOneWidget,
          reason: 'B6 (7120730242): busy pause/resume control spans the full grid row');
      final btn = tester.widget<ButtonStyleButton>(
        find.ancestor(of: find.text('Resuming…'), matching: find.bySubtype<ButtonStyleButton>()).first,
      );
      expect(btn.onPressed, isNull);
    });
  });

  group('U60: 2-column tonal device action grid with 48 dp targets (#650, 7119037302)', () {
    for (final locale in const [Locale('en'), Locale('ar')]) {
      testWidgets('390px @ 200% (${locale.languageCode}): 2-column tonal grid, >=48dp targets, zero overflow',
          (tester) async {
        // Mutant 1: reverting to TextButton.icon fails the FilledButton type assertion.
        // Mutant 2: dropping minimumSize 48dp fails the height >= 48.0 assertion.
        // Mutant 3: reverting to single-column Wrap removes deviceActionGrid2Col.
        tester.view.physicalSize = const Size(390, 1600);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        final api = FakeApiClient({
          ...standardRoutes(),
          'GET /v1/devices/dev-1/commands/history': (_) => history(const []),
        });
        await tester.pumpWidget(ProviderScope(
          overrides: [apiClientProvider.overrideWithValue(api)],
          child: MediaQuery(
            data: const MediaQueryData(size: Size(390, 1600), textScaler: TextScaler.linear(2.0)),
            child: localizedTestApp(
              const ChildDetailScreen(childId: 'child-1'),
              locale: locale,
              textDirection: locale.languageCode == 'ar' ? TextDirection.rtl : TextDirection.ltr,
            ),
          ),
        ));
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        expect(find.byKey(const ValueKey('deviceActionGrid2Col')), findsOneWidget);

        const keys = [
          'deviceAction-ring-dev-1',
          'deviceAction-stopRing-dev-1',
          'deviceAction-lock-dev-1',
          'deviceAction-unlock-dev-1',
          'deviceAction-pause-dev-1',
          'deviceAction-history-dev-1',
          'deviceAction-internet-dev-1',
        ];
        for (final k in keys) {
          final f = find.byKey(ValueKey(k));
          expect(f, findsOneWidget, reason: 'missing tonal button $k');
          expect(tester.widget(f), isA<FilledButton>(), reason: '$k must be a tonal FilledButton');
          expect(tester.getSize(f).height, greaterThanOrEqualTo(48.0), reason: '$k must have >= 48 dp target');
        }
      });
    }
  });

}
